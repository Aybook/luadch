--[[

        http.lua - Phase 8 S3 HTTP request router (drives #82)

        Maps a parsed/rejected HTTP request unit (produced by the
        hardened iostream.newhttpstage framer) to a minimal HTTP
        response, writes it, and closes the connection (one request
        per connection - no keep-alive; see docs/phases/PHASE_8_IO.md).

        S3 ships ONLY /health (static 200 "ok", no auth, no data). The
        #82 read endpoints (/users /stats /version, token auth, JSON)
        are a separate follow-up PR with its own security review - this
        module is deliberately tiny and exposes nothing sensitive.

        Security notes:
          - no `Server` header (no version fingerprint pre-auth)
          - fixed minimal headers, explicit Content-Length, always
            Connection: close
          - transport hardening already happened in the framer; a
            { reject = <status> } unit is answered with a canned body
          - log lines sanitise the path (control bytes already
            rejected upstream - defence in depth, no log injection)

]]--

----------------------------------// DECLARATION //--

local use = use

local out = use "out"
local string = use "string"
local iostream = use "iostream"

local out_put = out.put
local string_sub = string.sub
local string_gsub = string.gsub
local tostring = use "tostring"

local _status
local response
local logsafe
local handle
local http_incoming
local http_disconnect

----------------------------------// DEFINITION //--

_status = {
    [ 200 ] = "200 OK",
    [ 400 ] = "400 Bad Request",
    [ 404 ] = "404 Not Found",
    [ 405 ] = "405 Method Not Allowed",
    [ 414 ] = "414 URI Too Long",
    [ 431 ] = "431 Request Header Fields Too Large",
    [ 505 ] = "505 HTTP Version Not Supported",
}

response = function( status, body, headonly )
    local line = _status[ status ] or "500 Internal Server Error"
    body = body or ""
    local head = "HTTP/1.1 " .. line .. "\r\n"
        .. "Content-Type: text/plain; charset=utf-8\r\n"
        .. "Content-Length: " .. #body .. "\r\n"
        .. "Connection: close\r\n"
        .. "\r\n"
    if headonly then
        return head
    end
    return head .. body
end

-- defence in depth: the framer already rejects any control byte in
-- the target, but never interpolate request data into a log line
-- without neutralising CR/LF and capping length.
logsafe = function( s )
    s = string_gsub( tostring( s or "" ), "%c", "?" )
    if #s > 80 then
        s = string_sub( s, 1, 80 ) .. "..."
    end
    return s
end

handle = function( handler, req )
    local status, body, headonly

    if req.reject then
        status = req.reject
        body = ( _status[ status ] or "error" ) .. "\n"
        out_put( "http.lua: rejected request, status ", status )
    elseif req.method ~= "GET" and req.method ~= "HEAD" then
        status, body = 405, "405 Method Not Allowed\n"
        out_put( "http.lua: 405 method ", logsafe( req.method ) )
    else
        headonly = ( req.method == "HEAD" )
        if req.target == "/health" then
            status, body = 200, "ok\n"
        else
            status, body = 404, "404 Not Found\n"
            out_put( "http.lua: 404 ", logsafe( req.target ) )
        end
    end

    handler.write( response( status, body, headonly ) )
    handler.close( )    -- graceful: flush the response, then close
    return true
end

-- server.lua calls the listener's `incoming` once at accept with no
-- data (we ignore that), then once per framed unit with the parsed
-- request. No hub user object is created for an HTTP connection.
http_incoming = function( handler, req )
    if not req then
        return true
    end
    return handle( handler, req )
end

http_disconnect = function( )
    -- no per-connection state to tear down
end

----------------------------------// PUBLIC INTERFACE //--

return {

    -- listener spec for server.addserver: the `pipeline` field makes
    -- server.lua build the hardened HTTP framer pipeline for these
    -- connections instead of the default ADC-line one.
    listeners = function( )
        return {
            incoming   = http_incoming,
            disconnect = http_disconnect,
            pipeline   = iostream.newhttppipeline,
        }
    end,

}
