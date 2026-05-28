--[[

    http_client.lua - non-blocking outbound HTTP(S) client.

    luadch is single-threaded: one select() event loop in
    core/server.lua. A blocking socket.http / ssl.https call would
    freeze the WHOLE hub (every connected user) until it returned.
    This module makes outbound requests WITHOUT blocking, by driving
    a non-blocking socket through a coroutine registered on the
    existing `server.addtimer` (the same ~1s timer the HTTP-API event
    long-poll uses). It touches NO server.lua internals - only the
    public `server.addtimer` - so the inbound connection hot path is
    untouched.

    Latency note: the timer fires ~once per second, so each I/O step
    that must WAIT (connect-completion, more-data) costs up to ~1s.
    Each tick makes maximal progress (drains all available bytes,
    finishes any non-blocking write) and only yields when it would
    block. A small request to a reachable host typically completes in
    1-3 ticks. This is intended for BACKGROUND outbound (hublist
    announce, webhooks) where a few seconds of latency is irrelevant -
    NOT for anything on a user-facing request path.

    Security / trust model:
      - Plugins are trusted (docs/SECURITY.md s2); `socket` + `ssl`
        are already exposed to the sandbox, so this grants no new
        capability - it is the SAFE, non-blocking way to use it.
      - The helper does NOT allowlist URLs. Callers MUST NOT pass a
        URL derived from untrusted (ADC-client) input (SSRF). The
        bundled callers use operator-configured cfg URLs only.
      - Hard bounds: per-request deadline (timeout), response size
        cap, and a global in-flight cap so a buggy caller cannot
        spawn unbounded timer coroutines.
      - TLS verification is the caller's choice via `verify`/`cafile`
        (LuaSec has no default CA store). Default is "none": the
        channel is then NOT authenticated - fine for POSTing public
        data (a hub announcing its public address), NOT for secrets.

    API:
      http_client.request{
          url         = "https://host[:port]/path",  -- http:// or https://
          method      = "POST",        -- default "GET"
          body        = "...",         -- optional request body
          headers     = { ... },       -- optional extra request headers
          timeout     = 15,            -- seconds (default 15, clamped 1..120)
          max_response = 65536,        -- response byte cap (default 64 KiB)
          verify      = "none",        -- "none" | "peer" (TLS only)
          cafile      = nil,           -- CA bundle path when verify="peer"
          on_complete = function( res ) end,  -- res = { status, headers, body }
          on_error    = function( err ) end,  -- err = string
      }
      Returns true if the request was queued, or (false, err) if it
      was rejected synchronously (bad url / in-flight cap reached).

]]--

local use = use

local type     = use "type"
local tostring = use "tostring"
local tonumber = use "tonumber"
local pcall    = use "pcall"
local pairs    = use "pairs"

local string    = use "string"
local table     = use "table"
local socket    = use "socket"
local ssl       = use "ssl"
local out       = use "out"
local coroutine = use "coroutine"

local coroutine_create = coroutine.create
local coroutine_yield  = coroutine.yield
local string_match     = string.match
local string_lower     = string.lower
local string_len       = string.len
local string_find      = string.find
local table_concat     = table.concat
local socket_gettime   = socket.gettime
local out_put          = out.put
local out_error        = out.error

-- // bounds //
local DEFAULT_TIMEOUT   = 15
local MIN_TIMEOUT       = 1
local MAX_TIMEOUT       = 120
local DEFAULT_MAX_RESP  = 64 * 1024
local MAX_RESP_CEIL     = 1024 * 1024   -- hard ceiling even if caller asks for more
local MAX_INFLIGHT      = 16            -- global cap on concurrent requests
local READ_CHUNK        = 16 * 1024

local _inflight = 0

-- Reject CR/LF (and other control bytes) in any value that gets
-- interpolated into the request line / headers - otherwise a caller
-- (or an operator-cfg value) carrying "\r\n" could split the request
-- or smuggle extra headers. Network-I/O input validation per
-- CLAUDE.md s1a.1, regardless of the trusted-caller model.
local function has_ctrl( s )
    return type( s ) ~= "string" or string_find( s, "[%c]" ) ~= nil
end

-- Parse a URL into ( scheme, host, port, path ) or ( nil, err ).
-- Deliberately small: we control the URLs (operator cfg). No auth /
-- query / fragment handling beyond passing the path through. Does
-- NOT allowlist the host (caller's responsibility - see SSRF note in
-- the header); but DOES reject control bytes, embedded credentials,
-- and bracketed IPv6 literals (unsupported - use a hostname).
local function parse_url( url )
    if type( url ) ~= "string" then return nil, "url must be a string" end
    if has_ctrl( url ) then return nil, "url contains control bytes" end
    local scheme, hostport, path = string_match( url, "^(%w+)://([^/]+)(/?.*)$" )
    if not scheme then return nil, "malformed url" end
    scheme = string_lower( scheme )
    if scheme ~= "http" and scheme ~= "https" then
        return nil, "unsupported scheme '" .. scheme .. "' (http/https only)"
    end
    if string_find( hostport, "@" ) then
        return nil, "embedded credentials in url not supported"
    end
    if string_find( hostport, "%[" ) then
        return nil, "bracketed IPv6 literal not supported - use a hostname"
    end
    local host, port = string_match( hostport, "^([^:]+):?(%d*)$" )
    if not host or host == "" then return nil, "missing host" end
    port = tonumber( port )
    if not port then port = ( scheme == "https" ) and 443 or 80 end
    if port < 1 or port > 65535 then return nil, "port out of range" end
    if path == "" then path = "/" end
    return scheme, host, port, path
end

-- Build the raw HTTP/1.1 request bytes. Connection: close so the
-- server closes after the response and our read loop ends on EOF.
local function build_request( method, host, port, path, body, headers )
    local lines = {
        method .. " " .. path .. " HTTP/1.1",
        "Host: " .. host .. ( ( port ~= 80 and port ~= 443 ) and ( ":" .. port ) or "" ),
        "Connection: close",
        "User-Agent: luadch-http-client",
    }
    local have = { host = true, connection = true, [ "user-agent" ] = true, [ "content-length" ] = true }
    if headers then
        for k, v in pairs( headers ) do
            if not have[ string_lower( k ) ] then
                lines[ #lines + 1 ] = k .. ": " .. v
            end
        end
    end
    if body and body ~= "" then
        lines[ #lines + 1 ] = "Content-Length: " .. string_len( body )
    end
    return table_concat( lines, "\r\n" ) .. "\r\n\r\n" .. ( body or "" )
end

-- Parse a complete raw HTTP response into { status, headers, body }.
local function parse_response( raw )
    local head, body = string_match( raw, "^(.-)\r\n\r\n(.*)$" )
    if not head then
        -- No header terminator seen (truncated / non-HTTP). Treat the
        -- whole thing as head, empty body.
        head, body = raw, ""
    end
    local status = tonumber( string_match( head, "^HTTP/%d%.%d%s+(%d%d%d)" ) )
    local headers = {}
    local first = true
    for line in head:gmatch( "([^\r\n]+)" ) do
        if first then
            first = false
        else
            local k, v = string_match( line, "^([^:]+):%s*(.*)$" )
            if k then headers[ string_lower( k ) ] = v end
        end
    end
    return { status = status, headers = headers, body = body }
end

local function safe_cb( fn, arg )
    if type( fn ) == "function" then
        local ok, err = pcall( fn, arg )
        if not ok then
            out_error( "http_client: callback raised: " .. tostring( err ) )
        end
    end
end

-- The non-blocking state machine, run inside a coroutine that yields
-- back to the select loop between I/O steps. Never blocks.
local function drive( req )
    local deadline = socket_gettime( ) + req.timeout
    local function expired( ) return socket_gettime( ) > deadline end

    local scheme, host, port, path = parse_url( req.url )
    -- (parse already validated in request(); re-deriving here is cheap)

    local sock, err = socket.tcp( )
    if not sock then return false, "socket.tcp failed: " .. tostring( err ) end
    sock:settimeout( 0 )

    -- // connect (non-blocking) //
    local ok
    ok, err = sock:connect( host, port )
    while not ok and ( err == "timeout" or err == "Operation already in progress" ) do
        if expired( ) then sock:close( ); return false, "connect timeout" end
        coroutine_yield( )
        ok, err = sock:connect( host, port )
        -- a completed non-blocking connect re-reports as this:
        if err == "already connected" then ok, err = true, nil end
    end
    if not ok and err ~= "already connected" then
        sock:close( ); return false, "connect failed: " .. tostring( err )
    end

    -- // TLS handshake (https) //
    if scheme == "https" then
        -- Floor at TLS 1.2: protocol="any" but disable SSLv3 / TLS 1.0
        -- / TLS 1.1 via options, so a downgrade to a broken protocol
        -- is not silently accepted even with verify="none".
        local params = {
            mode     = "client",
            protocol = "any",
            verify   = req.verify or "none",
            options  = { "all", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
            cafile   = req.cafile,
        }
        local wrapped
        wrapped, err = ssl.wrap( sock, params )
        if not wrapped then sock:close( ); return false, "ssl.wrap failed: " .. tostring( err ) end
        sock = wrapped
        sock:settimeout( 0 )
        if sock.sni then pcall( function( ) sock:sni( host ) end ) end
        local hok
        hok, err = sock:dohandshake( )
        while not hok and ( err == "wantread" or err == "wantwrite" or err == "timeout" ) do
            if expired( ) then sock:close( ); return false, "tls handshake timeout" end
            coroutine_yield( )
            hok, err = sock:dohandshake( )
        end
        if not hok then sock:close( ); return false, "tls handshake failed: " .. tostring( err ) end
    end

    -- // send request (handle partial writes) //
    local payload = build_request( req.method, host, port, path, req.body, req.headers )
    local sent = 0
    local total = string_len( payload )
    while sent < total do
        if expired( ) then sock:close( ); return false, "send timeout" end
        local n, serr, partial = sock:send( payload, sent + 1 )
        if n then
            sent = n
        elseif serr == "wantwrite" or serr == "wantread" or serr == "timeout" then
            sent = partial or sent
            coroutine_yield( )
        else
            sock:close( ); return false, "send failed: " .. tostring( serr )
        end
    end

    -- // receive response (accumulate until close or cap) //
    local chunks = {}
    local got = 0
    while true do
        if expired( ) then sock:close( ); return false, "read timeout" end
        local data, rerr, partial = sock:receive( READ_CHUNK )
        local piece = data or partial
        if piece and piece ~= "" then
            got = got + string_len( piece )
            if got > req.max_response then
                sock:close( ); return false, "response exceeds max_response cap"
            end
            chunks[ #chunks + 1 ] = piece
        end
        if rerr == "closed" then
            break    -- EOF: full response received
        elseif rerr == nil or rerr == "wantread" or rerr == "wantwrite" or rerr == "timeout" then
            -- Always yield back to the select loop between reads -
            -- including after a full READ_CHUNK (rerr == nil). Never
            -- loop on the socket without yielding, so a fast / large
            -- response can never pin the single hub thread. Total
            -- bytes are still bounded by max_response.
            coroutine_yield( )
        else
            sock:close( ); return false, "read failed: " .. tostring( rerr )
        end
    end
    sock:close( )

    return true, parse_response( table_concat( chunks ) )
end

local request

request = function( req )
    if type( req ) ~= "table" then return false, "request: arg must be a table" end
    if type( req.url ) ~= "string" then return false, "request: url required" end

    -- validate url synchronously so the caller gets immediate feedback
    local scheme, perr = parse_url( req.url )
    if not scheme then return false, perr end

    -- CRLF / control-byte guard on everything that gets interpolated
    -- into the request line + headers (anti request-smuggling).
    req.method = req.method or "GET"
    if has_ctrl( req.method ) then return false, "method contains control bytes" end
    if req.body ~= nil and type( req.body ) ~= "string" then
        return false, "body must be a string"
    end
    if req.headers ~= nil then
        if type( req.headers ) ~= "table" then return false, "headers must be a table" end
        for k, v in pairs( req.headers ) do
            if has_ctrl( k ) or has_ctrl( tostring( v ) ) then
                return false, "header contains control bytes"
            end
        end
    end

    if _inflight >= MAX_INFLIGHT then
        return false, "http_client: in-flight cap (" .. MAX_INFLIGHT .. ") reached"
    end

    -- normalise + clamp
    local t = tonumber( req.timeout ) or DEFAULT_TIMEOUT
    if t < MIN_TIMEOUT then t = MIN_TIMEOUT elseif t > MAX_TIMEOUT then t = MAX_TIMEOUT end
    req.timeout = t
    local m = tonumber( req.max_response ) or DEFAULT_MAX_RESP
    if m < 1 then m = DEFAULT_MAX_RESP elseif m > MAX_RESP_CEIL then m = MAX_RESP_CEIL end
    req.max_response = m

    local server = use "server"
    if type( server.addtimer ) ~= "function" then
        return false, "http_client: server.addtimer unavailable"
    end

    _inflight = _inflight + 1
    local co = coroutine_create( function( )
        -- pcall so a thrown error in drive() still decrements
        -- _inflight (otherwise a crash leaks an in-flight slot and,
        -- after MAX_INFLIGHT crashes, the helper jams). server.lua's
        -- timer loop ignores coroutine.resume errors, so we MUST
        -- handle them here.
        local pok, a, b = pcall( drive, req )
        _inflight = _inflight - 1
        if not pok then
            out_error( "http_client: request to ", tostring( req.url ), " crashed: ", tostring( a ) )
            safe_cb( req.on_error, "internal error" )
        elseif a == true then
            safe_cb( req.on_complete, b )
        else
            out_put( "http_client: request to ", tostring( req.url ), " failed: ", tostring( a == false and b or a ) )
            safe_cb( req.on_error, ( a == false and b ) or a )
        end
    end )
    server.addtimer( co )
    return true
end

return {
    request        = request,
    -- exposed for unit tests
    _parse_url     = parse_url,
    _build_request = build_request,
    _parse_response = parse_response,
    _has_ctrl      = has_ctrl,
}
