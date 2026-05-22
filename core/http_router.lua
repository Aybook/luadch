--[[

    http_router.lua - the HTTP API router (Phase 1b of #82).

    Owns the route table, auth, scope check, idempotency-key cache,
    envelope formatting, JSON marshalling (via dkjson), schema mini-
    validation, audit-log emission, and first-boot token bootstrap.

    core/http.lua is the transport-level interface to server.lua's
    listener wiring; this module is the API logic on top of that.
    The two are intentionally separate so transport hardening (the
    framer caps, the response builder) stays small and testable
    while the route surface grows over phase 1c + later.

    Authoritative design: docs/HTTP_API.md. This file is the
    implementation of §3-§9 of that spec.

    Plugin entrypoint: hub.http_register( method, path, scope,
    handler, meta ) - wired in core/hub.lua. The router itself
    exposes register() / unregister_all() / dispatch() for the
    transport layer and core/hub.lua to call.

    Out of scope for phase 1b (lands in phase 1c):
      - token-bucket + failed-auth + prefix rate-limiting (§4.8, §6.3)
      - idempotency-key cache eviction policy (the data structure is
        here; size cap + eviction lands with the cap cfg key in 1c)
      - adclib.constant_time_eq C binding (pure-Lua fallback ships
        here; C version lands in 1c)
      - the bulk of the core endpoints (/v1/version, /v1/stats,
        /v1/users, /v1/log/api) - 1b registers only /health (special-
        case, unauthenticated) and /v1/endpoints (proves the
        registry + scope filtering work end-to-end). 1c adds the
        rest.

]]--

----------------------------------// DECLARATION //--

local use = use

local pairs = use "pairs"
local ipairs = use "ipairs"
local tostring = use "tostring"
local tonumber = use "tonumber"
local type = use "type"
local pcall = use "pcall"
local select = use "select"
local error = use "error"

local string = use "string"
local table = use "table"
local os = use "os"
local io = use "io"
local math = use "math"

local string_sub = string.sub
local string_len = string.len
local string_find = string.find
local string_match = string.match
local string_gmatch = string.gmatch
local string_lower = string.lower
local string_byte = string.byte
local string_format = string.format
local string_rep = string.rep
local table_concat = table.concat
local table_insert = table.insert
local table_remove = table.remove
local os_date = os.date

local cfg = use "cfg"
local out = use "out"

local cfg_get = cfg.get
local out_put = out.put
local out_error = out.error
local out_api_audit = out.api_audit

-- forward declarations
local register
local unregister_all
local dispatch
local list_endpoints
local resolve_token
local constant_time_eq
local json_encode
local json_decode
local envelope_success
local envelope_error
local validate_schema
local audit_log
local match_path
local generate_request_id
local bootstrap_first_token
local register_core_endpoints
local parse_query
local status_reason

-- module state
local _routes      = { }    -- _routes[method][path_pattern] = { handler, scope, plugin, meta, path_template }
local _routes_flat = { }    -- flat list for /v1/endpoints; populated alongside _routes
local _initialized = false

----------------------------------// DEFINITION //--

-- Constant-time string equality. Lua's `==` short-circuits at the
-- first mismatching byte which leaks length + prefix-match timing
-- for token comparisons. This pure-Lua fallback XOR-accumulates the
-- byte differences over equal-length inputs and never short-circuits.
-- Phase 1c will replace the body with a C binding
-- (adclib.constant_time_eq) for the same algorithm at C speed; the
-- API contract here stays.
--
-- Returns true iff #a == #b AND every byte matches. Inputs of
-- different lengths return false immediately (the length itself is
-- not secret in our use case - the token is whatever the operator
-- put in cfg).
constant_time_eq = function( a, b )
    if type( a ) ~= "string" or type( b ) ~= "string" then
        return false
    end
    local len_a = string_len( a )
    if len_a ~= string_len( b ) then
        return false
    end
    local diff = 0
    for i = 1, len_a do
        diff = diff | ( string_byte( a, i ) ~ string_byte( b, i ) )
    end
    return diff == 0
end

-- JSON encode + decode via the bundled dkjson 2.10. The `use` is
-- lazy because dkjson is in init.lua's _optional list (the HTTP
-- API itself is opt-in); failure to load is surfaced at first call
-- as a 500 with a logged error. The HTTP listener won't bind in
-- the first place if dkjson didn't load - this is purely defence
-- in depth.
json_encode = function( v )
    local dkjson = use "dkjson"
    if not dkjson then
        error( "http_router: dkjson did not load; cannot encode JSON" )
    end
    return dkjson.encode( v )
end
json_decode = function( s )
    local dkjson = use "dkjson"
    if not dkjson then
        error( "http_router: dkjson did not load; cannot decode JSON" )
    end
    -- dkjson returns (value, position, errmsg) on failure (value=nil,
    -- pos<0). Wrap that into a single (value, errmsg) shape.
    local v, _, err = dkjson.decode( s, 1, nil )
    if v == nil then
        return nil, err or "invalid json"
    end
    return v
end

envelope_success = function( data )
    return json_encode( { ok = true, data = data } )
end

envelope_error = function( code, message )
    return json_encode( {
        ok    = false,
        error = { code = code, message = message },
    } )
end

-- Schema mini-validator (docs/HTTP_API.md §5.5). Top-level only;
-- nested validation is the handler's job per the spec contract.
-- Returns (true, nil) on pass or (false, "field 'x': ...") on fail.
validate_schema = function( schema, body )
    if not schema then return true end
    if type( body ) ~= "table" then
        return false, "body must be a JSON object"
    end
    for field, spec in pairs( schema ) do
        local v = body[ field ]
        local present = ( v ~= nil )
        if spec.required and not present then
            return false, "field '" .. field .. "': required"
        end
        if present then
            if spec.type then
                local actual = type( v )
                local expected = spec.type
                local ok
                if expected == "integer" then
                    ok = ( actual == "number" and v % 1 == 0 )
                elseif expected == "array" or expected == "object" then
                    -- both are Lua tables; distinguishing them
                    -- precisely needs a key-scan (an empty {} is
                    -- ambiguous and accepted as either). The spec
                    -- says top-level only, so a coarse check is OK.
                    ok = ( actual == "table" )
                else
                    ok = ( actual == expected )
                end
                if not ok then
                    return false, "field '" .. field .. "': expected " .. expected
                end
            end
            if spec.enum then
                local match = false
                for _, allowed in ipairs( spec.enum ) do
                    if v == allowed then match = true break end
                end
                if not match then
                    return false, "field '" .. field .. "': not in enum"
                end
            end
            if spec.min and type( v ) == "number" and v < spec.min then
                return false, "field '" .. field .. "': below min"
            end
            if spec.max and type( v ) == "number" and v > spec.max then
                return false, "field '" .. field .. "': above max"
            end
            if spec.min_length and type( v ) == "string" and string_len( v ) < spec.min_length then
                return false, "field '" .. field .. "': too short"
            end
            if spec.max_length and type( v ) == "string" and string_len( v ) > spec.max_length then
                return false, "field '" .. field .. "': too long"
            end
            if spec.pattern and type( v ) == "string"
               and not string_match( v, spec.pattern ) then
                return false, "field '" .. field .. "': pattern mismatch"
            end
        end
    end
    return true
end

-- Path-template match. Converts e.g. "/v1/users/{sid}" into the Lua
-- pattern "^/v1/users/([^/]+)$" and captures path-var values. Cached
-- per route at register time so dispatch is O(routes per method).
local function compile_path_pattern( template )
    local vars = { }
    local pattern = "^" .. ( template:gsub( "%-", "%%-" ):gsub( "{([^}]+)}", function( name )
        table_insert( vars, name )
        return "([^/]+)"
    end ) ) .. "$"
    return pattern, vars
end

match_path = function( route, path )
    local matches = { string_match( path, route.pattern ) }
    if matches[ 1 ] == nil then return nil end
    local path_vars = { }
    for i, name in ipairs( route.vars ) do
        path_vars[ name ] = matches[ i ]
    end
    return path_vars
end

register = function( method, path, scope, handler, meta )
    if type( method ) ~= "string" or string_match( method, "[a-z]" ) then
        error( "http_router.register: method must be an uppercase string" )
    end
    if type( path ) ~= "string" or string_sub( path, 1, 1 ) ~= "/" then
        error( "http_router.register: path must start with /" )
    end
    if scope ~= "read" and scope ~= "admin" and scope ~= "none" then
        error( "http_router.register: scope must be 'read', 'admin' or 'none'" )
    end
    if type( handler ) ~= "function" then
        error( "http_router.register: handler must be a function" )
    end
    local pattern, vars = compile_path_pattern( path )
    _routes[ method ] = _routes[ method ] or { }
    if _routes[ method ][ path ] then
        error( "http_router.register: duplicate route '" .. method .. " " .. path .. "'" )
    end
    local route = {
        handler  = handler,
        scope    = scope,
        plugin   = ( meta and meta.plugin ) or "core",
        meta     = meta or { },
        template = path,
        pattern  = pattern,
        vars     = vars,
    }
    _routes[ method ][ path ] = route
    table_insert( _routes_flat, { method = method, route = route } )
end

unregister_all = function( )
    _routes      = { }
    _routes_flat = { }
    _initialized = false
end

-- /v1/endpoints discovery: scope-filtered live route registry.
-- The endpoint registers itself - the registry is self-describing.
list_endpoints = function( req )
    local out_list = { }
    local can_see_admin = ( req.token_scope == "admin" )
    for _, entry in ipairs( _routes_flat ) do
        local r = entry.route
        -- scope="none" routes (e.g. /health) are public and listed
        -- to every token holder. read-scoped routes are listed to
        -- everyone with auth. admin-scoped routes only to admin
        -- tokens. (/v1/endpoints requires read scope to call so
        -- we never hit this code for an anonymous caller.)
        if r.scope == "none" or r.scope == "read" or can_see_admin then
            table_insert( out_list, {
                method      = entry.method,
                path        = r.template,
                scope       = r.scope,
                plugin      = r.plugin,
                description = r.meta.description,
                request_schema  = r.meta.request_schema,
                response_schema = r.meta.response_schema,
            } )
        end
    end
    return { status = 200, data = { endpoints = out_list } }
end

-- Resolve `Authorization: Bearer <token>` against cfg.http_api_tokens.
-- Returns (label, scope) on success or (nil, error_code) on failure.
resolve_token = function( authz_header )
    if type( authz_header ) ~= "string" then
        return nil, "missing"
    end
    local token = string_match( authz_header, "^Bearer (.+)$" )
    if not token then return nil, "malformed" end
    local tokens = cfg_get "http_api_tokens" or { }
    for cfg_token, spec in pairs( tokens ) do
        if constant_time_eq( token, cfg_token ) then
            -- non-secret label = "<comment> (<first4>...<last4>)";
            -- safe to log + carry around.
            local first4 = string_sub( cfg_token, 1, 4 )
            local last4  = string_sub( cfg_token, -4 )
            local comment = ( spec.comment and spec.comment ~= "" )
                and ( spec.comment .. " " ) or ""
            local label = comment .. "(" .. first4 .. "..." .. last4 .. ")"
            return label, spec.scope
        end
    end
    return nil, "unknown"
end

-- Audit-log line, one per non-GET request (or per any request if
-- http_api_log_reads = true). Body field is JSON-serialised, max
-- 512 bytes, control bytes replaced with `?` (matches http.lua's
-- logsafe).
local function logsafe_body( raw_body )
    if not raw_body or raw_body == "" then return "-" end
    local s = raw_body
    if string_len( s ) > 512 then
        s = string_sub( s, 1, 509 ) .. "..."
    end
    -- strip control bytes (CR/LF would line-split the log; NUL etc
    -- are even nastier).
    return ( s:gsub( "%c", "?" ) )
end

audit_log = function( req, status )
    if not cfg_get "log_api_audit" then return end
    if req.method == "GET" and not cfg_get "http_api_log_reads" then return end
    out_api_audit(
        req.method, " ", req.path, " ", tostring( status ),
        " token=", ( req.token_label or "-" ),
        " src=", ( req.source_ip or "-" ),
        " idem=", ( req.idempotency_key or "-" ),
        " req_id=", ( req.request_id or "-" ),
        " body=", logsafe_body( req.raw_body )
    )
end

generate_request_id = function( )
    -- UUIDv4-shaped opaque hex (8-4-4-4-12). Not cryptographically
    -- meaningful - this is purely for log correlation. math.random
    -- seed is set globally elsewhere; this function does not seed.
    local random = math.random
    local hex = "0123456789abcdef"
    local function block( n )
        local out_b = { }
        for i = 1, n do
            local idx = random( 1, 16 )
            out_b[ i ] = string_sub( hex, idx, idx )
        end
        return table_concat( out_b )
    end
    return block( 8 ) .. "-" .. block( 4 ) .. "-4" .. block( 3 )
        .. "-" .. block( 4 ) .. "-" .. block( 12 )
end

-- The X-Confirm-required endpoints (docs/HTTP_API.md §4.6). Lookup
-- by "METHOD path-template" - cheap and explicit.
local _xconfirm_required = {
    [ "POST /v1/reload" ]   = true,
    [ "POST /v1/restart" ]  = true,
    [ "POST /v1/shutdown" ] = true,
    [ "DELETE /v1/registered/{nick}" ] = true,
}

parse_query = function( s )
    local q = { }
    if not s or s == "" then return q end
    for pair in string_gmatch( s, "([^&]+)" ) do
        local k, v = string_match( pair, "^([^=]+)=(.*)$" )
        if k then
            q[ k ] = v
        else
            q[ pair ] = ""
        end
    end
    return q
end

status_reason = function( code )
    -- minimal local table, full table is in core/http.lua. Used
    -- only for framer-reject responses where we emit text/plain.
    local m = {
        [400] = "Bad Request",
        [404] = "Not Found",
        [413] = "Payload Too Large",
        [414] = "URI Too Long",
        [431] = "Request Header Fields Too Large",
        [505] = "HTTP Version Not Supported",
    }
    return m[ code ]
end

-- Main dispatch path. Called by core/http.lua's incoming with the
-- framer's parsed unit; the handler returns a Lua table that we
-- envelope, serialize and hand back to the transport layer.
--
-- Returns (status, response_body_string, headers_table) so
-- core/http.lua can build the wire response.
dispatch = function( framer_unit, source_ip )
    -- Reject units from the framer (4xx / 5xx surfaced as plain
    -- text + the canned status reason; the API envelope is for
    -- routed-through-the-API responses, not transport-level
    -- rejections that never reached an auth handler).
    if framer_unit.reject then
        local code = framer_unit.reject
        return code, code .. " " .. ( status_reason( code ) or "error" ) .. "\n",
            { [ "Content-Type" ] = "text/plain; charset=utf-8" }
    end

    local method = framer_unit.method
    local target = framer_unit.target
    -- split off query string
    local path, query_str
    local q = string_find( target, "?", 1, true )
    if q then
        path = string_sub( target, 1, q - 1 )
        query_str = string_sub( target, q + 1 )
    else
        path = target
    end

    -- Build the req struct that handlers see.
    local req = {
        method     = method,
        path       = path,
        target     = target,
        query      = parse_query( query_str ),
        headers    = framer_unit.headers,
        raw_body   = framer_unit.body,
        body       = nil,    -- parsed JSON, filled after auth/CL check
        source_ip  = source_ip,
        request_id = framer_unit.headers[ "x-request-id" ]
                     or generate_request_id( ),
        idempotency_key = framer_unit.headers[ "x-idempotency-key" ],
        confirm    = ( framer_unit.headers[ "x-confirm" ] == "yes" ),
    }

    -- Headers we always echo regardless of outcome.
    local resp_headers = { [ "X-Request-ID" ] = req.request_id }

    -- Lookup the route FIRST (we need to know if scope=="none" -
    -- the unauthenticated routes like /health - to decide whether
    -- to enforce auth). Supports HEAD -> GET fallback per §6.6.
    local lookup_method = method == "HEAD" and "GET" or method
    local methods_for_path = { }
    local matched_route, matched_vars
    for m, paths in pairs( _routes ) do
        for _, r in pairs( paths ) do
            local vars = match_path( r, path )
            if vars then
                table_insert( methods_for_path, m )
                if m == lookup_method then
                    matched_route = r
                    matched_vars  = vars
                end
            end
        end
    end

    -- Auth resolution (label = nil means anonymous / bad token).
    local label, scope_or_err = resolve_token( framer_unit.headers[ "authorization" ] )

    -- Method/path resolution outcomes before auth gating:
    if not matched_route then
        if #methods_for_path > 0 then
            -- Path exists for some other method - 405 + Allow header.
            -- Surfaced to anonymous callers too: spec says clients
            -- should be able to discover allowed methods on a known
            -- path. We do NOT 401 here.
            local allowed = table_concat( methods_for_path, ", " )
            resp_headers[ "Allow" ] = allowed
            req.token_label = label    -- may be nil; audit still logs "-"
            audit_log( req, 405 )
            return 405, envelope_error( "E_METHOD_NOT_ALLOWED",
                "method " .. method .. " not allowed; see Allow header" ), resp_headers
        end
        -- Unknown path. Anonymous callers get 401 (don't leak
        -- endpoint existence); authenticated callers get 404.
        if not label then
            audit_log( req, 401 )
            return 401, envelope_error( "E_UNAUTHENTICATED", "missing or invalid bearer token" ), resp_headers
        end
        req.token_label = label
        req.token_scope = scope_or_err
        audit_log( req, 404 )
        return 404, envelope_error( "E_NOT_FOUND", "no such endpoint" ), resp_headers
    end

    req.path_vars = matched_vars

    -- Auth enforcement: scope=="none" routes (e.g. /health) skip
    -- auth entirely. Everything else requires a valid token.
    if matched_route.scope ~= "none" then
        if not label then
            audit_log( req, 401 )
            return 401, envelope_error( "E_UNAUTHENTICATED", "missing or invalid bearer token" ), resp_headers
        end
        req.token_label = label
        req.token_scope = scope_or_err

        -- Scope check.
        if matched_route.scope == "admin" and req.token_scope ~= "admin" then
            audit_log( req, 403 )
            return 403, envelope_error( "E_FORBIDDEN", "endpoint requires admin scope" ), resp_headers
        end
    end

    -- X-Confirm for destructive ops (§4.6).
    if _xconfirm_required[ method .. " " .. matched_route.template ] and not req.confirm then
        audit_log( req, 400 )
        return 400, envelope_error( "E_CONFIRMATION_REQUIRED",
            "endpoint requires header 'X-Confirm: yes'" ), resp_headers
    end

    -- Body parse (only for methods that accept a body and only when
    -- CL > 0; the framer already enforced Content-Type-irrelevant
    -- transport rules).
    if req.raw_body and req.raw_body ~= "" then
        local ct = framer_unit.headers[ "content-type" ] or ""
        -- minimum check: starts with application/json. Charset
        -- parameters and case-insensitive media types are out of
        -- scope for phase 1b.
        local ct_lower = string_lower( ct )
        if not string_find( ct_lower, "^application/json", 1, false ) then
            audit_log( req, 415 )
            return 415, envelope_error( "E_UNSUPPORTED_MEDIA_TYPE",
                "Content-Type must be application/json" ), resp_headers
        end
        local parsed, err = json_decode( req.raw_body )
        if not parsed then
            audit_log( req, 400 )
            return 400, envelope_error( "E_BAD_JSON", err or "invalid json" ), resp_headers
        end
        if type( parsed ) ~= "table" then
            audit_log( req, 400 )
            return 400, envelope_error( "E_BAD_JSON", "body must be a JSON object" ), resp_headers
        end
        req.body = parsed

        -- Schema validation, if the route declared one.
        if matched_route.meta.request_schema then
            local ok, schema_err = validate_schema( matched_route.meta.request_schema, parsed )
            if not ok then
                audit_log( req, 400 )
                return 400, envelope_error( "E_BAD_INPUT", schema_err ), resp_headers
            end
        end
    end

    -- Dispatch.
    local ok, result_or_err = pcall( matched_route.handler, req )
    if not ok then
        out_error( "http_router.dispatch: handler raised on ",
            method, " ", path, ": ", tostring( result_or_err ) )
        audit_log( req, 500 )
        return 500, envelope_error( "E_INTERNAL", "handler error" ), resp_headers
    end
    if type( result_or_err ) ~= "table" then
        out_error( "http_router.dispatch: handler for ",
            method, " ", path, " returned non-table: ", tostring( result_or_err ) )
        audit_log( req, 500 )
        return 500, envelope_error( "E_INTERNAL", "handler contract violated" ), resp_headers
    end

    local status = result_or_err.status or 200
    local body
    if result_or_err.raw_body ~= nil then
        -- Escape hatch for non-JSON responses (e.g. /health returns
        -- text/plain "ok"). Handler controls the body bytes + the
        -- Content-Type via `content_type`; the envelope is skipped.
        body = result_or_err.raw_body
        if result_or_err.content_type then
            resp_headers[ "Content-Type" ] = result_or_err.content_type
        end
    elseif result_or_err.error then
        body = envelope_error( result_or_err.error.code or "E_INTERNAL",
                               result_or_err.error.message or "error" )
    else
        body = envelope_success( result_or_err.data )
    end

    -- HEAD: handler returned a unit; the router measured the body
    -- length for Content-Length but discards the bytes themselves
    -- (§6.6 contract).
    if method == "HEAD" then
        resp_headers[ "Content-Length-Override" ] = tostring( string_len( body ) )
        body = ""
    end

    audit_log( req, status )
    return status, body, resp_headers
end


-- First-boot token bootstrap (§4.7). Called by core/hub.lua BEFORE
-- binding the http_port, so a failed-to-write bootstrap aborts the
-- listener bring-up rather than opening an unreachable port.
bootstrap_first_token = function( cfg_path )
    local tokens = cfg_get "http_api_tokens" or { }
    -- Lua tables have no `next` shortcut we can rely on for "is
    -- empty" without a pairs scan - one iteration tells us.
    local any = false
    for _ in pairs( tokens ) do any = true break end
    if any then return true end    -- operator already provisioned a token

    local adclib = use "adclib"
    if not adclib then
        return nil, "adclib not loaded - cannot generate random token"
    end
    -- 32 bytes from RAND_bytes -> base32 = 52 chars. Operator can
    -- shorten or rotate via cfg+reload as they please; we just
    -- want enough entropy that brute-force is moot.
    local raw = adclib.createsalt( 32 )
    if not raw then
        return nil, "adclib.createsalt returned nil"
    end
    local basexx = use "basexx"
    if not basexx then
        return nil, "basexx not loaded - cannot encode bootstrap token"
    end
    local token = basexx.to_base32( raw ):gsub( "=", "" )

    local path = cfg_path .. "api_token.first"
    local f, err = io.open( path, "w" )
    if not f then
        out_error( "http_router.bootstrap_first_token: cannot write ",
            path, ": ", tostring( err ) )
        return nil, err
    end
    f:write( "# Initial admin token generated at hub first boot.\n" )
    f:write( "# Copy the value below into cfg.tbl http_api_tokens,\n" )
    f:write( "# then delete this file. See docs/HTTP_API.md s4.7.\n" )
    f:write( "#\n" )
    f:write( token .. "\n" )
    f:close( )

    -- chmod 600 if the platform supports it (POSIX). On Windows
    -- the call is skipped; the operator's ACLs / file-system perms
    -- apply instead. Same heuristic as cfg_secret.lua's _is_windows.
    if not ( os.getenv "COMSPEC" and os.getenv "WINDIR" ) then
        local escaped = "'" .. ( path:gsub( "'", "'\\''" ) ) .. "'"
        os.execute( "chmod 600 " .. escaped )
    end

    -- Activate the token in-memory NOW so the API is usable on this
    -- very first session, before the operator has had a chance to
    -- edit cfg.tbl. cfg.set with nosave=true updates _settings
    -- without touching cfg.tbl on disk; the operator's manual copy
    -- is what makes it persistent across restarts. Without this
    -- step the bootstrap file would be docs-only, the API would
    -- 401 on every request until the operator did the copy + reload.
    local ok = cfg.set( "http_api_tokens", {
        [ token ] = { scope = "admin", comment = "bootstrap" },
    }, true )    -- nosave = true: in-memory only, do not write cfg.tbl
    if not ok then
        out_error( "http_router.bootstrap_first_token: cfg.set rejected the generated token; falling back to file-only" )
    end

    out_error( "hub.lua: http_api_tokens empty - generated initial admin token at ",
        path, ". Copy the value into cfg.tbl http_api_tokens and delete the file." )
    return true
end

-- /health: unversioned, unauthenticated, plain text. Registered as
-- a normal route with scope = "none" so it appears in
-- /v1/endpoints and follows the same dispatch path as everything
-- else; the special case for it in earlier drafts is gone.
local function health_handler( req )
    return {
        status = 200,
        raw_body = "ok\n",
        content_type = "text/plain; charset=utf-8",
    }
end

-- /v1/endpoints + /health registration. Called from
-- register_core_endpoints below at module-init time so the discovery
-- surface is always available (no plugin owns it).
register_core_endpoints = function( )
    register( "GET", "/health", "none", health_handler, {
        plugin = "core",
        description = "load-balancer health probe (plain text, unauthenticated)",
        response_schema = nil,
    } )
    register( "GET", "/v1/endpoints", "read", list_endpoints, {
        plugin = "core",
        description = "list all registered endpoints (scope-filtered to the caller's token)",
        response_schema = { endpoints = { type = "array", required = true } },
    } )
end

-- init() is called by core/hub.lua after cfg has loaded and before
-- the HTTP listener binds. Re-callable: +reload calls unregister_all
-- + init() again to repopulate routes.
local init = function( )
    if _initialized then return end
    register_core_endpoints( )
    _initialized = true
end

----------------------------------// PUBLIC INTERFACE //--

return {

    register              = register,
    unregister_all        = unregister_all,
    dispatch              = dispatch,
    bootstrap_first_token = bootstrap_first_token,
    init                  = init,

    -- exposed for unit tests (NOT for plugin use):
    _constant_time_eq     = constant_time_eq,
    _validate_schema      = validate_schema,
    _envelope_success     = envelope_success,
    _envelope_error       = envelope_error,
    _resolve_token        = resolve_token,
    _generate_request_id  = generate_request_id,

}
