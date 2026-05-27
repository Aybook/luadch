--[[

    http_events.lua

        Event ringbuffer + emit/poll for the HTTP API's
        `GET /v1/events` endpoint (#263 of #82).

        PR-A scope: immediate-return polling only. Client GETs,
        server returns whatever has accumulated in the ringbuffer
        since the supplied `?since=` cursor. Client polls again.
        Long-polling (server-side wait + coroutine yield) lands in
        PR-B.

        Events are appended via `emit(type, payload)` from two
        sources:

          1. The core-side tap registered into scripts.firelistener
             via scripts.register_tap - captures every event the
             rest of the hub fires via the existing listener-chain
             machinery (onLogin / onLogout / onBroadcast / onReg /
             onDelreg / onPrivateMessage / onFailedAuth / onError /
             onSearch). No plugin changes needed for these.

          2. Direct emit calls from plugins that want to advertise
             events that don't have a listener-chain counterpart
             (ban_added / ban_removed / topic_changed - PR-B will
             wire these as the plugins migrate).

        The ringbuffer is bounded by cfg `http_events_buffer_size`
        (default 1000). When a client's `since=` cursor falls
        below the buffer's minimum id, the response carries
        `cursor_lost: true` and the client catches up via the
        per-resource GET endpoints, then resumes polling at the
        returned `cursor`.

]]--

----------------------------------// DECLARATION //--

local type = use "type"
local ipairs = use "ipairs"
local pairs = use "pairs"
local pcall = use "pcall"
local tonumber = use "tonumber"
local tostring = use "tostring"

local os = use "os"
local table = use "table"

local os_date         = os.date
local os_time         = os.time
local table_insert    = table.insert
local table_remove    = table.remove

local cfg = use "cfg"

local util = use "util"
local strip_control_bytes = util.strip_control_bytes

----------------------------------// DEFINITION //--

local DEFAULT_BUFFER_SIZE = 1000

local _buffer = { }      -- array: ringbuffer of {id, type, timestamp, payload...}
local _next_id = 1       -- monotonic counter; never reset within a process lifetime
local _max_size           -- cached cfg.get("http_events_buffer_size")

local _iso_now = function( )
    return os_date( "!%Y-%m-%dT%H:%M:%SZ", os_time( ) )
end

-- Sanitise every string value in a payload table at emit time so
-- consumers never see raw control bytes that came in from ADC
-- frames. Recurses one level (event payloads are flat per spec).
local _sanitise = function( payload )
    if type( payload ) ~= "table" then return { } end
    local clean = { }
    for k, v in pairs( payload ) do
        if type( v ) == "string" then
            clean[ k ] = strip_control_bytes( v )
        else
            clean[ k ] = v
        end
    end
    return clean
end

-- Append an event to the ringbuffer. Drops the oldest entry when
-- the buffer is at cap. Public; callable from any module (core or
-- plugin sandbox - http_events is whitelisted).
--
-- Re-reads cfg.http_events_buffer_size on every emit so a live PUT
-- /v1/config/{key} change takes effect immediately - the cfg key
-- is classified `live` in #262, and capturing the cap at init()
-- would silently no-op the operator's edit.
local emit = function( event_type, payload )
    if type( event_type ) ~= "string" or event_type == "" then return end
    local clean = _sanitise( payload )
    clean.id        = _next_id
    clean.type      = event_type
    clean.timestamp = _iso_now( )
    _next_id = _next_id + 1
    table_insert( _buffer, clean )
    local cap = tonumber( cfg.get( "http_events_buffer_size" ) ) or DEFAULT_BUFFER_SIZE
    if cap < 1 then cap = DEFAULT_BUFFER_SIZE end
    while #_buffer > cap do
        table_remove( _buffer, 1 )
    end
end

-- Map a comma-separated `types=` query param into a lookup table.
-- Returns nil if the filter is absent (= all types pass).
local _parse_types_filter = function( q )
    if q == nil or q == "" then return nil end
    local set = { }
    for piece in tostring( q ):gmatch( "[^,]+" ) do
        local trimmed = piece:match( "^%s*(.-)%s*$" )
        if trimmed and trimmed ~= "" then
            set[ trimmed ] = true
        end
    end
    return set
end

-- Read events with id > since that match the optional type filter.
-- Returns ( rows, cursor, cursor_lost ).
--   rows         array of event tables (each has id/type/timestamp + payload)
--   cursor       the highest id we've handed out so far (caller's next `since`)
--   cursor_lost  true if `since` is below the buffer's minimum id (oldest evicted)
-- This is the immediate-return path. PR-B adds the wait/yield variant.
--
-- NB: this function does NOT do scope-based filtering. The HTTP
-- handler is responsible for masking `pm` events from read-scope
-- tokens. Plugins calling poll() directly see everything (matches
-- the documented trust contract in docs/SECURITY.md §2).
local poll = function( since_raw, types_filter_raw )
    local since = tonumber( since_raw )
    if since == nil then
        if since_raw == "latest" then
            -- Client signals "I just want the latest cursor, no replay" -
            -- return empty + the current cursor so next poll picks up new
            -- events only.
            return { }, _next_id - 1, false
        end
        since = 0
    end
    if since < 0 then since = 0 end
    local types_filter = _parse_types_filter( types_filter_raw )

    -- Cursor-lost detection: if `since` is less than the buffer's
    -- minimum id AND the buffer is non-empty, we have lost events.
    local cursor_lost = false
    if #_buffer > 0 then
        local min_id = _buffer[ 1 ].id
        if since < min_id - 1 then
            cursor_lost = true
        end
    end

    local rows = { }
    for _, ev in ipairs( _buffer ) do
        if ev.id > since then
            if types_filter == nil or types_filter[ ev.type ] then
                rows[ #rows + 1 ] = ev
            end
        end
    end
    local cursor = _next_id - 1
    return rows, cursor, cursor_lost
end

-- Map a scripts.firelistener call (ltype + up-to-five args) into a
-- public event-type + payload. Returns ( event_type, payload ) or
-- ( nil ) for ltypes we deliberately don't surface.
local _listener_arg_to_event = function( ltype, a1, a2, a3, a4, a5 )
    if ltype == "onLogin" then
        -- a1 = user
        if not a1 then return nil end
        return "login", {
            nick  = a1.nick  and a1:nick( )  or "",
            sid   = a1.sid   and a1:sid( )   or "",
            level = a1.level and a1:level( ) or 0,
        }
    end
    if ltype == "onLogout" then
        if not a1 then return nil end
        return "logout", {
            nick = a1.nick and a1:nick( ) or "",
            sid  = a1.sid  and a1:sid( )  or "",
        }
    end
    if ltype == "onBroadcast" then
        -- a1 = user, a2 = adccmd (unused), a3 = decoded text
        if not a1 then return nil end
        return "broadcast", {
            nick    = a1.nick and a1:nick( ) or "",
            sid     = a1.sid  and a1:sid( )  or "",
            message = a3 or "",
        }
    end
    if ltype == "onPrivateMessage" then
        -- core/hub_dispatch.lua fires this as
        -- (user, targetuser, adccmd, decoded_text). a3 is the
        -- adccmd TABLE (NOT the message - early PR-A draft got
        -- this wrong); a4 is the escapefrom-decoded text.
        if not a1 then return nil end
        return "pm", {
            from_nick = ( type( a1 ) == "table" and a1.nick and a1:nick( ) ) or tostring( a1 ),
            to_nick   = ( type( a2 ) == "table" and a2.nick and a2:nick( ) ) or tostring( a2 or "" ),
            message   = tostring( a4 or "" ),
        }
    end
    if ltype == "onFailedAuth" then
        -- a1 = nick (string), a2 = ip, a3 = cid, a4 = reason
        return "failed_auth", {
            nick      = tostring( a1 or "" ),
            source_ip = tostring( a2 or "" ),
            reason    = tostring( a4 or "" ),
        }
    end
    if ltype == "onReg" then
        return "reg_added", {
            nick = tostring( a1 or "" ),
        }
    end
    if ltype == "onDelreg" then
        return "reg_removed", {
            nick = tostring( a1 or "" ),
        }
    end
    if ltype == "onError" then
        return "script_error", {
            message = tostring( a1 or "" ),
        }
    end
    return nil
end

-- The tap callback registered into scripts.firelistener. Wrapped
-- in pcall by scripts.lua so a bad mapping here can't cascade
-- into the listener-chain's contract.
local _firelistener_tap = function( ltype, a1, a2, a3, a4, a5 )
    local event_type, payload = _listener_arg_to_event( ltype, a1, a2, a3, a4, a5 )
    if event_type then
        emit( event_type, payload )
    end
end

local init = function( )
    _max_size = tonumber( cfg.get( "http_events_buffer_size" ) ) or DEFAULT_BUFFER_SIZE
    if _max_size < 1 then _max_size = DEFAULT_BUFFER_SIZE end
    local scripts = use "scripts"
    if type( scripts.register_tap ) == "function" then
        scripts.register_tap( _firelistener_tap )
    end
end

----------------------------------// PUBLIC INTERFACE //--

return {
    init  = init,
    emit  = emit,
    poll  = poll,
    -- Test / introspection helpers (NOT for plugin use).
    _buffer_size = function( ) return #_buffer end,
    _next_id     = function( ) return _next_id end,
}
