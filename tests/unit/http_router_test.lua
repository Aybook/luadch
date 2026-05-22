--[[

    tests/unit/http_router_test.lua

    Unit tests for the pure-Lua-bit functions of core/http_router.lua
    (constant_time_eq, validate_schema, envelope helpers, token
    resolution, schema validator, request-id shape). Dispatch is
    smoke-tested end-to-end against a real hub.

    The router uses `use "cfg"` and `use "out"` and `use "dkjson"`
    at file scope; we stub them here so the module can load in a
    standalone interpreter.

    Run: lua5.4 tests/unit/http_router_test.lua
    Exit 0 = all pass, 1 = a failure (CI-friendly).

]]--

-- minimal `use` shim, lockstep with http_router.lua's imports.
local _stub_cfg_tokens = { }
local _last_audit_args = nil
local _mock_cfg = {
    get = function( key )
        if key == "http_api_tokens" then return _stub_cfg_tokens end
        if key == "log_api_audit" then return true end
        if key == "http_api_log_reads" then return false end
        return nil
    end,
}
local _mock_out = {
    put       = function() end,
    error     = function() end,
    api_audit = function( ... ) _last_audit_args = { ... } end,
}
local _mock_dkjson = {
    encode = function( v )
        -- minimal stub: just stringify with type discrimination.
        -- Real dkjson is bundled and gets exercised by smoke; here
        -- we only verify the router CALLS encode with the right
        -- shape. Returns the table as a sentinel.
        return { _encoded = v }
    end,
    decode = function( s )
        if type( s ) ~= "string" then return nil, nil, "not a string" end
        if s == "BAD" then return nil, nil, "stub: forced bad json" end
        -- the stub accepts the special prefix "OBJ:" + lua syntax
        if s:sub( 1, 4 ) == "OBJ:" then
            local fn, err = loadstring and loadstring( "return " .. s:sub( 5 ) )
                or load( "return " .. s:sub( 5 ) )
            if not fn then return nil, nil, err end
            local ok, t = pcall( fn )
            if not ok then return nil, nil, t end
            return t
        end
        return nil, nil, "stub: only OBJ:{...} accepted"
    end,
}

local _real = {
    string = string, table = table, os = os, io = io, math = math,
    pairs = pairs, ipairs = ipairs, tostring = tostring, tonumber = tonumber,
    type = type, pcall = pcall, select = select, error = error,
    cfg = _mock_cfg, out = _mock_out, dkjson = _mock_dkjson,
}
_G.use = function( name )
    local v = _real[ name ]
    assert( v ~= nil, "http_router_test shim missing dep: use \"" .. name .. "\"" )
    return v
end

local router = assert( loadfile( "core/http_router.lua" ) )( )

local failures, checks = 0, 0
local function eq( label, got, want )
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        io.write( string.format( "FAIL %-50s got=%q want=%q\n",
            label, tostring( got ), tostring( want ) ) )
    else
        io.write( string.format( "ok   %s\n", label ) )
    end
end

----------------------------------------------------------------------
-- constant_time_eq
----------------------------------------------------------------------

eq( "cte: equal strings",          router._constant_time_eq( "abc", "abc" ), true )
eq( "cte: different strings",      router._constant_time_eq( "abc", "abd" ), false )
eq( "cte: different lengths",      router._constant_time_eq( "abc", "abcd" ), false )
eq( "cte: empty equal",            router._constant_time_eq( "", "" ), true )
eq( "cte: non-string a",           router._constant_time_eq( nil, "x" ), false )
eq( "cte: non-string b",           router._constant_time_eq( "x", 42 ), false )
eq( "cte: byte-precise difference at position 1",
    router._constant_time_eq( "abc", "abx" ), false )

----------------------------------------------------------------------
-- validate_schema
----------------------------------------------------------------------

do
    local schema = {
        target = { type = "string", required = true, max_length = 64 },
        duration_minutes = { type = "integer", min = 1, max = 525600 },
        scope = { type = "string", enum = { "all", "hub", "level" } },
    }
    local ok, err
    ok = router._validate_schema( schema, { target = "x", scope = "all" } )
    eq( "schema: minimum valid", ok, true )

    ok, err = router._validate_schema( schema, { } )
    eq( "schema: missing required", ok, false )

    ok, err = router._validate_schema( schema, { target = 42 } )
    eq( "schema: wrong type", ok, false )

    ok = router._validate_schema( schema,
        { target = "x", duration_minutes = 60 } )
    eq( "schema: integer ok", ok, true )

    ok, err = router._validate_schema( schema,
        { target = "x", duration_minutes = 1.5 } )
    eq( "schema: integer rejects float", ok, false )

    ok, err = router._validate_schema( schema,
        { target = "x", scope = "everyone" } )
    eq( "schema: enum mismatch", ok, false )

    ok, err = router._validate_schema( schema,
        { target = string.rep( "x", 65 ) } )
    eq( "schema: max_length exceeded", ok, false )

    ok, err = router._validate_schema( schema,
        { target = "x", duration_minutes = 0 } )
    eq( "schema: below min", ok, false )

    eq( "schema: nil schema -> ok",
        router._validate_schema( nil, { } ), true )
end

----------------------------------------------------------------------
-- envelope helpers
----------------------------------------------------------------------

do
    local e = router._envelope_success( { x = 1 } )
    -- mock dkjson.encode returns { _encoded = v }; we assert the
    -- shape the router built.
    eq( "envelope: success ok flag", e._encoded.ok, true )
    eq( "envelope: success data x", e._encoded.data.x, 1 )

    local f = router._envelope_error( "E_BAD_INPUT", "bad field" )
    eq( "envelope: error ok flag", f._encoded.ok, false )
    eq( "envelope: error code", f._encoded.error.code, "E_BAD_INPUT" )
    eq( "envelope: error message", f._encoded.error.message, "bad field" )
end

----------------------------------------------------------------------
-- resolve_token
----------------------------------------------------------------------

do
    _stub_cfg_tokens = {
        [ "admin-tokens-here" ] = { scope = "admin", comment = "ops cli" },
        [ "readonlytoken99" ]   = { scope = "read",  comment = "grafana" },
    }
    local label, scope = router._resolve_token( "Bearer admin-tokens-here" )
    eq( "resolve: admin scope", scope, "admin" )
    eq( "resolve: admin label has comment", label:find( "ops cli", 1, true ) ~= nil, true )
    eq( "resolve: admin label NO full secret",
        label:find( "tokens-here", 1, true ), nil )

    local _, scope_r = router._resolve_token( "Bearer readonlytoken99" )
    eq( "resolve: read scope", scope_r, "read" )

    local nil_l, err = router._resolve_token( "Bearer nope-not-a-token" )
    eq( "resolve: unknown -> nil", nil_l, nil )
    eq( "resolve: unknown -> error code", err, "unknown" )

    nil_l, err = router._resolve_token( "MalformedHeader" )
    eq( "resolve: no Bearer -> malformed", err, "malformed" )

    nil_l, err = router._resolve_token( nil )
    eq( "resolve: missing -> missing", err, "missing" )
end

----------------------------------------------------------------------
-- generate_request_id shape (8-4-4-4-12 hex)
----------------------------------------------------------------------

do
    local id = router._generate_request_id( )
    eq( "req-id: length",
        #id, 36 )
    eq( "req-id: pattern matches UUIDv4-shape",
        id:match( "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$" ) ~= nil,
        true )
end

----------------------------------------------------------------------
-- register + unregister_all + duplicate rejection
----------------------------------------------------------------------

do
    router.unregister_all( )

    -- Register fresh; succeeds.
    local handler = function( ) return { status = 200, data = { } } end
    local ok = pcall( router.register, "GET", "/v1/foo", "read", handler )
    eq( "register: fresh route ok", ok, true )

    -- Duplicate same method+path rejects.
    local ok2 = pcall( router.register, "GET", "/v1/foo", "read", handler )
    eq( "register: duplicate route rejected", ok2, false )

    -- Different method on same path: ok.
    local ok3 = pcall( router.register, "POST", "/v1/foo", "admin", handler )
    eq( "register: same path different method ok", ok3, true )

    -- Lowercase method rejected.
    local ok4 = pcall( router.register, "get", "/v1/bar", "read", handler )
    eq( "register: lowercase method rejected", ok4, false )

    -- Invalid scope rejected.
    local ok5 = pcall( router.register, "GET", "/v1/bar", "guest", handler )
    eq( "register: invalid scope rejected", ok5, false )

    -- Path must start with /
    local ok6 = pcall( router.register, "GET", "v1/baz", "read", handler )
    eq( "register: path without / rejected", ok6, false )

    -- Non-function handler rejected.
    local ok7 = pcall( router.register, "GET", "/v1/qux", "read", "not-a-function" )
    eq( "register: non-function handler rejected", ok7, false )

    router.unregister_all( )
end

----------------------------------------------------------------------

io.write( string.format( "\n%d checks, %d failures\n", checks, failures ) )
os.exit( failures == 0 and 0 or 1 )
