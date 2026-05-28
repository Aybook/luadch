--[[

    etc_regserver_announce.lua by Aybo

        Announces this hub to an external ADC hublist regserver by
        POSTing the hub's public info (an ADC IINF line) to the
        regserver's /register endpoint. The regserver records the
        hub; external ADC pingers take over liveness + removal.

        Opt-in + event-driven, per the regserver design agreed with
        Hades:
          - OFF by default (etc_regserver_announce_activate). This is
            the privacy gate: a private hub simply leaves it off and
            never appears on the hublist (NMDC-protocol style).
          - Registers ONCE per hub address. The advertised address
            (HH = adcs://<hub_hostaddress>:<ssl_port>) is the dedup
            key. After a confirmed (2xx) registration the plugin goes
            quiet and does NOT re-announce until the address changes -
            re-announcing on a timer is wasted bandwidth (the pingers
            already track liveness).
          - On host change OR an unconfirmed registration it retries
            on a coarse interval (etc_regserver_announce_retry_interval,
            default 5 min) up to etc_regserver_announce_max_attempts,
            then gives up until the next +reload / restart.

        The POST is sent through core/http_client (NON-BLOCKING) so
        the single-threaded hub never freezes on a slow/unreachable
        regserver. Only PUBLIC hub fields are sent (name / app /
        version / address / description / website / network / owner /
        user count) - never any secret or internal state.

        v0.01: initial

]]--


--// settings begin //--

local scriptname = "etc_regserver_announce"
local scriptversion = "0.01"

--// settings end //--


--// table lookups
local hub_debug      = hub.debug
local hub_escapeto   = hub.escapeto
local hub_getusers   = hub.getusers
local cfg_get        = cfg.get
local util_loadtable = util.loadtable
local util_savetable = util.savetable
local os_time        = os.time
local table_concat   = table.concat
local tostring       = tostring
local pairs          = pairs
local ipairs         = ipairs

--// state file (persists the last confirmed HH across restarts so a
--// reload with an unchanged address does NOT re-announce)
local state_file = "scripts/data/etc_regserver_announce.tbl"

--// runtime state
local state        = { }      -- { last_hh = "..." } persisted
local confirmed    = false    -- current HH registered+confirmed this session?
local current_hh   = nil      -- HH we are trying to register
local attempts     = 0
local next_attempt = 0
local gave_up      = false
local in_flight    = false    -- a request is queued + not yet resolved

--// CODE

-- Derive the hub's advertised address (the regserver dedup key).
-- Prefer the TLS port (adcs://); fall back to plain (adc://).
local derive_hh = function( )
    local host = cfg_get( "hub_hostaddress" )
    if not host or host == "" or host == "your.host.addy.org" then
        return nil    -- operator has not set a real hostaddress
    end
    local ssl_ports = cfg_get( "ssl_ports" )
    if type( ssl_ports ) == "table" and ssl_ports[ 1 ] then
        return "adcs://" .. host .. ":" .. tostring( ssl_ports[ 1 ] )
    end
    local tcp_ports = cfg_get( "tcp_ports" )
    if type( tcp_ports ) == "table" and tcp_ports[ 1 ] then
        return "adc://" .. host .. ":" .. tostring( tcp_ports[ 1 ] )
    end
    return nil
end

-- Build the ADC IINF line from PUBLIC cfg fields only. Each value is
-- ADC-escaped via hub.escapeto (space -> \s etc) so it cannot break
-- the line / inject fields. HH + NI are required by the regserver;
-- empty optional fields are omitted.
local build_iinf = function( hh )
    local online = 0
    local nobots = hub_getusers( )    -- first return = humans-only
    if type( nobots ) == "table" then
        for _ in pairs( nobots ) do online = online + 1 end
    end
    local fields = {
        { "NI", cfg_get( "hub_name" ) },
        { "AP", const.PROGRAM_NAME },
        { "VE", const.VERSION },
        { "HH", hh },
        { "DE", cfg_get( "hub_description" ) },
        { "WS", cfg_get( "hub_website" ) },
        { "NE", cfg_get( "hub_network" ) },
        { "OW", cfg_get( "hub_owner" ) },
        { "UC", tostring( online ) },
    }
    local parts = { "IINF" }
    for _, f in ipairs( fields ) do
        local code, val = f[ 1 ], f[ 2 ]
        if val ~= nil and val ~= "" then
            parts[ #parts + 1 ] = code .. hub_escapeto( tostring( val ) )
        end
    end
    return table_concat( parts, " " )
end

-- Fire one (non-blocking) registration attempt.
local do_announce = function( )
    local hh = derive_hh( )
    if not hh then
        hub_debug( scriptname .. ": cannot derive hub address (hub_hostaddress / ports unset); skipping" )
        return
    end
    current_hh = hh
    local url = cfg_get( "etc_regserver_announce_url" )
    if not url or url == "" then
        hub_debug( scriptname .. ": etc_regserver_announce_url is empty; skipping" )
        return
    end
    local verify = cfg_get( "etc_regserver_announce_tls_verify" )
    local cafile = cfg_get( "etc_regserver_announce_cafile" )
    if verify and ( not cafile or cafile == "" ) then
        hub_debug( scriptname .. ": tls_verify is on but no cafile set; verification relies on the system trust store (LuaSec may have none)" )
    end
    local body = build_iinf( hh )

    in_flight = true
    local ok, err = http_client.request {
        url     = url,
        method  = "POST",
        body    = body,
        headers = { [ "Content-Type" ] = "text/plain" },
        timeout = 10,
        verify  = verify and "peer" or "none",
        cafile  = ( cafile and cafile ~= "" ) and cafile or nil,
        on_complete = function( res )
            in_flight = false
            if res.status and res.status >= 200 and res.status < 300 then
                confirmed = true
                state.last_hh = hh
                util_savetable( state, "state", state_file )
                hub_debug( scriptname .. ": registered with regserver (HTTP " .. tostring( res.status ) .. ", HH=" .. hh .. ")" )
            else
                hub_debug( scriptname .. ": regserver rejected registration (HTTP " .. tostring( res.status ) .. "); will retry" )
            end
        end,
        on_error = function( e )
            in_flight = false
            hub_debug( scriptname .. ": announce failed (" .. tostring( e ) .. "); will retry" )
        end,
    }
    if not ok then
        in_flight = false    -- not queued: no callback will fire
        hub_debug( scriptname .. ": request not queued: " .. tostring( err ) )
    end
end

hub.setlistener( "onStart", { },
    function( )
        if not cfg_get( "etc_regserver_announce_activate" ) then
            return nil
        end
        if not ( http_client and http_client.request ) then
            hub_debug( scriptname .. ": core/http_client unavailable; announce disabled" )
            return nil
        end
        state = util_loadtable( state_file ) or { }
        local hh = derive_hh( )
        if hh and state.last_hh == hh then
            -- Already registered for this address. Per the design we
            -- do NOT re-announce; the pingers maintain liveness.
            confirmed = true
            hub_debug( scriptname .. ": already registered for " .. hh .. " (no re-announce)" )
        else
            -- New / changed address (or never registered): announce on
            -- the next onTimer tick. http_client is non-blocking so we
            -- never stall the boot path.
            confirmed    = false
            attempts     = 0
            next_attempt = os_time( )
            gave_up      = false
        end
        return nil
    end
)

hub.setlistener( "onTimer", { },
    function( )
        if confirmed or gave_up then return nil end
        if in_flight then return nil end    -- don't overlap a pending request
        if not cfg_get( "etc_regserver_announce_activate" ) then return nil end
        local now = os_time( )
        if now < next_attempt then return nil end
        local max = cfg_get( "etc_regserver_announce_max_attempts" )
        if max and max > 0 and attempts >= max then
            gave_up = true
            hub_debug( scriptname .. ": giving up after " .. attempts .. " attempts (reload to retry)" )
            return nil
        end
        attempts = attempts + 1
        next_attempt = now + ( cfg_get( "etc_regserver_announce_retry_interval" ) or 300 )
        do_announce( )
        return nil
    end
)

hub_debug( "** Loaded " .. scriptname .. " " .. scriptversion .. " **" )
