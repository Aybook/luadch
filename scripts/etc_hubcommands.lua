--[[

        etc_hubcommands.lua v0.03 by blastbeat

        v0.06:
            - route the three operator-facing chat hints (the
              "[command]" echo, the "Did you mean +X?" forgot-prefix
              hint, and the literal-bracket hint) through lang. New
              lang file scripts/lang/etc_hubcommands.lang.{de,en}.
              Part of #301 i18n cleanup.

        v0.05: by Aybo
            - catch users who type the literal `[+!#]command` form
              with the doc-notation brackets included
                - closes luadch-ng/luadch#137 (Sopor)
                - same swallow-and-hint mechanism as the bare-word
                  case; the hint never echoes the input args because
                  the args can carry a password (e.g. `[+!#]reg
                  <user> <pw>`)

        v0.04: by Aybo
            - upstream #223: catch the bare-word "forgot the prefix"
              case for known commands and reply with a hint

        v0.03: by blastbeat
            - improve error handling

        v0.02: by pulsar
            - add support for multiple commands, usage: hubcmd.add( { cmd1, cmd2, cmd3 ... }, onbmsg )

        v0.01: by blastbeat
            - this script exports a module to reg hubcommands

]]--

--// settings begin //--

--// settings end //--

local scriptname = "etc_hubcommands"
local scriptversion = "0.06"

local utf_match = utf.match
local utf_format = utf.format
local hub_getbot = hub.getbot

-- #301 PR-4: route the three operator-facing chat hints through lang
-- (previously hardcoded English). Defaults preserve the pre-#301
-- wording so an en hub sees no change.
local scriptlang = cfg.get( "language" )
local lang, err = cfg.loadlanguage( scriptlang, scriptname ); lang = lang or {}; err = err and hub.debug( err )

local msg_command_echo     = lang.msg_command_echo     or "[command] %s"
local msg_did_you_mean     = lang.msg_did_you_mean     or "Did you mean +%s? Hub commands need the [+!#] prefix; your message was NOT sent to main chat."
local msg_literal_brackets = lang.msg_literal_brackets or "The `[+!#]` in the docs is notation for 'pick one of +, !, or #', not literal brackets. Try `+%s` (your message was NOT sent to main chat)."

local commands = { }

local reg_cmd = function( cmd, func )
    if ( type( cmd ) == "string" ) and ( type( func ) == "function" ) then
        if commands[ cmd ] then
            return false -- name is already registered
        end
        commands[ cmd ] = func
        return true
    end
    return false
end

local add = function( cmd, func ) -- quick and dirty...
    if type( cmd ) == "string" then
        cmd = { cmd }
    end
    if type( cmd ) == "table" then
        for _, name in pairs( cmd ) do
            if not reg_cmd( name, func ) then
                return false
            end
        end
        return true
    end
    return false
end

hub.setlistener( "onBroadcast", { },
    function( user, adccmd, txt )
        local cmd, parameters = utf_match( txt, "^[+!#](%a+) ?(.*)" )
        local func = commands[ cmd ]
        if func then
            user:reply( utf_format( msg_command_echo, txt ), hub_getbot( ) )
            return func( user, cmd, parameters, txt )
        end
        -- Closes upstream luadch/luadch#223: catch the common "forgot
        -- the [+!#] prefix" mistake. If the message starts with a
        -- known command name as a whole word and is the entire line
        -- or "cmd args" (no period / question mark / etc - so not
        -- mid-sentence chat), swallow the broadcast and remind the
        -- operator. Conservative match: only `^cmd$` or `^cmd <args>$`.
        local first_word = utf_match( txt, "^(%a+)$" ) or utf_match( txt, "^(%a+) " )
        if first_word and commands[ first_word ] then
            user:reply(
                utf_format( msg_did_you_mean, first_word ),
                hub_getbot( )
            )
            return PROCESSED
        end
        -- Closes luadch-ng/luadch#137 (Sopor): catch the "literal
        -- bracket" mistake. Users who are not familiar with the
        -- documentation notation type the form `[+!#]command` (or
        -- partial forms like `[+]command`, `[!#]command`) as if
        -- the brackets were part of the syntax. The literal-bracket
        -- message currently broadcasts as main-chat text, which can
        -- leak credentials when the user typed e.g.
        -- `[+!#]reg <user> <password>`. Swallow the broadcast and
        -- hint at the correct form. The hint does NOT echo the
        -- input args - only the command-name capture (`%a+`), which
        -- is never a password.
        local lit_cmd = utf_match( txt, "^%[[%+!#]+%](%a+)" )
        if lit_cmd and commands[ lit_cmd ] then
            user:reply(
                utf_format( msg_literal_brackets, lit_cmd ),
                hub_getbot( )
            )
            return PROCESSED
        end
        return nil
    end
)

hub.debug( "** Loaded "..scriptname.." "..scriptversion.." **" )

--// public //--

return {

    add = add,

}
