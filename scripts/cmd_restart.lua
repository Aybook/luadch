--[[

    cmd_restart.lua by blastbeat

        - this script adds a command "restart" to restart the hub
        - usage: [+!#]restart [<MSG>]

        v0.11: by pulsar
            - prevent message output if no reason given

        v0.10: by blastbeat
            - improve shutdown/exit logic

        v0.09: by pulsar
            - added "update_lastlogout" function
            - removed table lookups

        v0.08: by pulsar
            - possibility to send optional mass msg  / thx Sopor

        v0.07: by pulsar
            - add table lookups
            - clean code
            - removed "cmd_restart_minlevel" import
                - using util.getlowestlevel( tbl ) instead of "cmd_restart_minlevel"

        v0.06: by pulsar
            - export scriptsettings to "/cfg/cfg.tbl"

        v0.05: by pulsar
            - add ascii countdown mode
            - toggle countown on/off

        v0.04: by blastbeat
            - updated script api
            - renamed command
            - regged hubcommand

        v0.03: by blastbeat
            - added language files and ucmd

        v0.02: by blastbeat
            - updated script api

]]--


--------------
--[SETTINGS]--
--------------

local scriptname = "cmd_restart"
local scriptversion = "0.11"

local cmd = "restart"

--// imports
local hubcmd
local scriptlang = cfg.get( "language" )
local permission = cfg.get( "cmd_restart_permission" )
local toggle_countdown = cfg.get( "cmd_restart_toggle_countdown" )

--// msgs
local lang, err = cfg.loadlanguage( scriptlang, scriptname ); lang = lang or {}; err = err and hub.debug( err )

local help_title = lang.help_title or "cmd_restart.lua"
local help_usage = lang.help_usage or "[+!#]restart [<MSG>]"
local help_desc = lang.help_desc or "Restarts hub"

local ucmd_menu = lang.ucmd_menu or { "Hub", "Core", "Hub restart", "CLICK" }
local ucmd_msg = lang.ucmd_msg or "Mass Message (optional)"

local msg_denied = lang.msg_denied or "You are not allowed to use this command."
local msg_ok = lang.msg_ok or "Hub restarted."
local msg_hub_disabled = lang.msg_hub_disabled or "Hub is restarting."
local msg_countdown = lang.msg_countdown or "*** Hubrestart in ***"
local msg_restart = lang.msg_restart or [[


=== HUB RESTART ======================================================================================================

  %s

====================================================================================================== HUB RESTART ===

  ]]


----------
--[CODE]--
----------

local digital = {

    [0] = [[
                                                        ####
                                                        #     #
                                                        #     #
                                                        #     #
                                                        ####
        ]],
    [1] = [[
                                                           #
                                                           #
                                                           #
                                                           #
                                                           #
        ]],
    [2] = [[
                                                        ####
                                                               #
                                                        ####
                                                        #
                                                        ####
        ]],
    [3] = [[
                                                        ####
                                                               #
                                                        ####
                                                               #
                                                        ####
        ]],
    [4] = [[
                                                        #     #
                                                        #     #
                                                        ####
                                                               #
                                                               #
        ]],
    [5] = [[
                                                        ####
                                                        #
                                                        ####
                                                               #
                                                        ####
        ]],
    [6] = [[
                                                        ####
                                                        #
                                                        ####
                                                        #     #
                                                        ####
        ]],
    [7] = [[
                                                        ####
                                                               #
                                                               #
                                                               #
                                                               #
        ]],
    [8] = [[
                                                        ####
                                                        #     #
                                                        ####
                                                        #     #
                                                        ####
        ]],
    [9] = [[
                                                        ####
                                                        #     #
                                                        ####
                                                               #
                                                               #
        ]],
}

local minlevel = util.getlowestlevel( permission )
local list = { }
local countdown = 10

local update_lastlogout = function()
    local user_tbl = hub.getregusers()
    for i, v in pairs( user_tbl ) do
        if ( user_tbl[ i ].is_bot ~= 1 ) and ( user_tbl[ i ].is_online == 1 ) then
            user_tbl[ i ].lastlogout = util.date()
        end
    end
    cfg.saveusers( user_tbl )
end

local do_exit = function()
    -- T1.5 of #147: spec-compliant ISTA 212 emission ("Hub disabled")
    -- to every connected user before the socket close. The hub-disabled
    -- state is also the right code for a restart - "I'm going away,
    -- briefly, then coming back" - and prevents clients from treating
    -- the disconnect as a network glitch + immediate reconnect race.
    for _, u in pairs( hub.getusers() ) do
        u:sendsta( 212, msg_hub_disabled )
    end
    hub.shutdown()
    local starttime = os.time()
    return function()
        local diff = os.time() - starttime
        if diff >= 2 then
            update_lastlogout()
            hub.restart()
        end
    end
end

local do_countdown = function()
    local starttime = os.time()
    return function()
        if digital[ countdown ] then
            hub.broadcast( msg_countdown .. "\n\n" .. digital[ countdown ], hub.getbot() )
        end
        if countdown == 0 then
            hub.setlistener( "onTimer", {}, do_exit())
            countdown = -1
        elseif os.time() - starttime >= 1 then
            starttime = os.time()
            countdown = countdown - 1
        end
    end
end

local in_progress = false

-- Block main-chat broadcasts once a restart is queued: the hub will be
-- down in seconds, and the existing countdown messages are bot output
-- (not subject to onBroadcast) so the visual countdown remains visible.
hub.setlistener( "onBroadcast", { },
    function( )
        if in_progress then
            return PROCESSED
        end
    end
)

local onbmsg = function( user, command, parameters )
    if not permission[ user:level() ] then
        user:reply( msg_denied, hub.getbot() )
        return PROCESSED
    end
    if in_progress then -- restart was already issued
        return PROCESSED
    end
    in_progress = true
    local comment = utf.match( parameters, "^(.*)" )
    if comment ~= "" then
        hub.broadcast( utf.format( msg_restart, comment ), hub.getbot(), hub.getbot() )
    end
    if toggle_countdown then
        hub.setlistener( "onTimer", {}, do_countdown( ) )
    else
        hub.setlistener( "onTimer", {}, do_exit( ) )
        user:reply( msg_ok, hub.getbot() )
    end
    return PROCESSED
end

hub.setlistener( "onStart", { },
    function( )
        local help = hub.import( "cmd_help" )
        if help then
            help.reg( help_title, help_usage, help_desc, minlevel )
        end
        local ucmd = hub.import( "etc_usercommands" )  -- add usercommand
        if ucmd then
            ucmd.add( ucmd_menu, cmd, { "%[line:" .. ucmd_msg .. "]" }, { "CT1" }, minlevel )
        end
        hubcmd = hub.import( "etc_hubcommands" )  -- add hubcommand
        assert( hubcmd )
        assert( hubcmd.add( cmd, onbmsg ) )
        return nil
    end
)

hub.debug( "** Loaded " .. scriptname .. " " .. scriptversion .. " **" )
