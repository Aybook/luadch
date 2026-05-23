--[[

        scripts.lua by blastbeat

        - this script manages custom user scripts

]]--

----------------------------------// DECLARATION //--

--// lua functions //--

local type = use "type"
local error = use "error"
local pairs = use "pairs"
local pcall = use "pcall"
local ipairs = use "ipairs"
local loadfile = use "loadfile"
local tostring = use "tostring"
local setmetatable = use "setmetatable"

--// lua libs //--

local io = use "io"
local _G = use "_G"

--// lua lib methods //--

local io_open = io.open

--// extern libs //--

local adclib = use "adclib"
local unicode = use "unicode"

--// extern lib methods //--

local utf = unicode.utf8

local utf_sub = utf.sub
local adclib_isUtf8 = adclib.isutf8

--// core scripts //--

local adc = use "adc"
local cfg = use "cfg"
local out = use "out"
local mem = use "mem"
local util = use "util"

--// core methods //--

local cfg_get = cfg.get
local out_put = out.put
local mem_free = mem.free
local out_error = out.error
local handlebom = util.handlebom
local checkfile = util.checkfile

--// functions //--

local init
local index
local newindex

local import
local setenv
local killscripts
local firelistener
local startscripts
local listenermethod

--// tables //--

local _code
local _loaded
local _scripts
local _listeners

local _
local _len    -- len of listeners array

----------------------------------// DEFINITION //--

_len = 0

_loaded = { }
_scripts = { }    -- script names
_listeners = { }    -- array auf listeners tables of scripts

_code = {    -- mhh...

    hubbypass = 2,
    hubdispatch = 1,
    scriptsbypass = 8,
    scriptsdispatch = 4,

}

-- Plugin sandbox whitelist (Tier 1 of #206). Each plugin loaded
-- via `startscripts()` gets an _ENV table seeded with ONLY the
-- globals listed below; everything else in `_G` (the hub's runtime
-- namespace) is unreachable from plugin code.
--
-- Notably EXCLUDED (the genuinely-dangerous Lua VM primitives):
--   debug      VM introspection, getlocal/setlocal of other funcs,
--              metatable poking via debug.setmetatable
--   load       compile-arbitrary-string-to-callable
--   loadfile   compile-arbitrary-file-to-callable
--   dofile    load + immediately invoke arbitrary file
--   rawget    bypass __index trap (defeats strict-mode write detect)
--   rawset    bypass __newindex trap
--   rawlen    bypass __len trap
--   rawequal  bypass __eq trap
--   _G        the underlying global env (would re-expose everything)
--   _ENV      escape to parent env
--
-- Notably KEPT but flagged for Tier 2:
--   os, io     plugins use os.time / os.date / os.difftime + io.open
--              (read mode in cmd_errors / etc_keyprint) + io.popen
--              (cmd_hubinfo reads /proc & shells `uname`). A
--              follow-up tier will replace `os` and `io` with
--              curated shims that expose only the methods bundled
--              plugins actually need. For now exposed as-is so the
--              66-plugin audit stays green.
--   require    cmd_hubinfo / etc_keyprint use require("ssl") /
--              "ssl.x509" / "basexx". `ssl`/`basexx` are also in
--              the whitelist so plugins could `local ssl = ssl`,
--              but rewriting 4 require call sites is outside the
--              scope of this Tier-1 PR. require is constrained to
--              package.path / cpath (locked down in init.lua).
--   package    cmd_hubinfo:446 reads `package.config:sub(1,1)` for
--              the host's path separator. Exposed for the same
--              compat reason. Tier 2 should remove and replace
--              with a `util.path_sep` helper.
--
-- `hub`, `utf`, `string`, and `PROCESSED` are NOT in the whitelist
-- because they are written into env explicitly later (see lines
-- ~200-205 below) - `hub` gets a curated copy of the public hub
-- API (underscore-prefixed methods filtered out), `utf` is the
-- unicode shim, `string` is REPLACED with `utf` so plugins get
-- UTF-aware string functions instead of the byte-oriented standard
-- library, and `PROCESSED` is the listener-return constant.
local SANDBOX_GLOBALS = {
    -- Lua language basics (safe by spec)
    "assert", "error", "ipairs", "next", "pairs", "pcall", "print",
    "select", "tonumber", "tostring", "type", "xpcall",
    "setmetatable", "getmetatable", "collectgarbage",
    -- Standard libraries (safe)
    "table", "math", "coroutine",
    -- Compat-keep (see Tier-2 notes above)
    "os", "io", "require", "package",
    -- luadch core modules (always present in _G after init.lua)
    "cfg", "util", "util_http", "adc", "adclib", "signal", "out",
    "unicode",
    -- Extern + optional libs (some are `false` if their require()
    -- in init.lua failed - guarded by `or false` in the iterator below)
    "ssl", "socket", "basexx", "zlib_stream", "dkjson",
}

index = function( tbl, key )
    error( "attempt to read undeclared var: '" .. tostring( key ) .. "'", 2 )
end

newindex = function( tbl, key, value )
    error( "attempt to write undeclared var: '" .. tostring( key ) .. " = " .. tostring( value ) .. "'", 2 )
end

setenv = function( tbl )
    local mtbl = { }
    mtbl.__index = index
    mtbl.__newindex = newindex
    return setmetatable( tbl, mtbl )
end

listenermethod = function( arg, scriptid )
    if arg == "set" then
        local listeners = { }
        _listeners[ scriptid ] = listeners
        _len = _len + 1
        return function( ltype, id, func )
            listeners[ ltype ] = listeners[ ltype ] or { }
            listeners[ ltype ][ id ] = func
        end
    elseif arg == "get" then
        return function( ltype )
            local listeners = _listeners[ scriptid ]
            return listeners and listeners[ ltype ]
        end
    end
    -- removeListener counterpart tracked in issue #48
end

firelistener = function( ltype, a1, a2, a3, a4, a5 )
    local ret, dispatch
    for k = 1, _len do
        local listeners = _listeners[ k ][ ltype ]
        if listeners then
            for i, func in pairs( listeners ) do
                local bol, sret = pcall( func, a1, a2, a3, a4, a5 )
                if bol then
                    ret = ret or sret
                elseif ltype ~= "onError" then    -- no endless loops ^^
                    out_error( "scripts.lua: script error: ", sret, " (listener: ", ltype, "; script: '", _scripts[ k ], "')" )
                end
            end

            --// ugly shit //--

            --[[if ret == 6 or ret == 10 then
                dispatch = dispatch or 0
            end
            if ret == 5 or ret == 9 then
                dispatch = dispatch or 1
            end
            if ret == 9 or ret == 10 then
                break
            end]]

            if ret == 10 then    -- PROCESSED should be enough
                return true
            end
        end
    end
    --return ( dispatch == 0 )
    return false
end

startscripts = function( hub )
    for key, scriptname in ipairs( cfg_get "scripts" ) do
        local path = cfg_get( "script_path" ) .. scriptname
        local ret, err = checkfile( path )
        if not ret then
            out_error( "scripts.lua: format error in script '", scriptname, "': ", err )
        else
            -- Build the script's _ENV table BEFORE loadfile, so we can pass it
            -- as the 3rd loadfile argument (Lua 5.4 idiom; setfenv is gone).
            local hubobject = { }
            for name, method in pairs( hub ) do
                if utf_sub( name, 1, 1 ) ~= "_" then    -- no "hidden" functions...
                    hubobject[ name ] = method
                end
            end
            local key = _len + 1
            hubobject.setlistener = listenermethod( "set", key )    -- this is needed to execute listeners in script order
            hubobject.getlistener = listenermethod( "get", key )
            local env =  { }

            --// useful constants //--

            --env.DISPATCH_HUB = _code.hubdispatch
            --env.DISCARD_HUB = _code.hubbypass
            --env.DISPATCH_SCRIPTS = _code.scriptsdispatch
            --env.DISCARD_SCRIPTS = _code.scriptsbypass

            env.PROCESSED = _code.scriptsbypass + _code.hubbypass    -- should be enough

            -- Sandbox whitelist (Tier 1 of #206). Replaces the
            -- previous verbatim `for k,v in pairs(_G) do env[k]=v end`
            -- which exposed `debug`, `loadfile`, `dofile`, `load`,
            -- `rawget/rawset` etc. to every plugin. The new
            -- behaviour: ONLY names in `SANDBOX_GLOBALS` are
            -- imported from _G; everything else is unreachable
            -- (`env.debug` is nil, indexing it raises
            -- "attempt to index nil value" or - with the optional
            -- `setenv` trap below - the explicit "undeclared var"
            -- error). Curated `hub` / `utf` / `string` overrides
            -- happen after this loop.
            for _, name in ipairs( SANDBOX_GLOBALS ) do
                env[ name ] = _G[ name ]
            end
            env.hub = hubobject
            env.utf = utf
            env.string = utf
            -- `no_global_scripting` cfg key (default true): with the
            -- explicit whitelist above, accessing a forbidden global
            -- like `debug` already raises "attempt to index nil
            -- value" at the plugin's first dereference. The setenv()
            -- wrapper merely UPGRADES the error to the more explicit
            -- "attempt to read undeclared var: 'debug'" via __index,
            -- AND adds an __newindex trap that blocks
            -- plugin-created globals (`myvar = 5` outside a `local`
            -- binding). The cfg key remains for the __newindex
            -- behaviour - legacy plugins that create globals
            -- unintentionally rely on the lax mode. Operators who
            -- want maximum strictness leave the default true.
            -- Candidate for deprecation alongside the Tier 2 os/io
            -- curation pass for #206.
            if cfg_get "no_global_scripting" then
                setenv( env )
            end

            ret, err = loadfile( path, "t", env )
            if not ret then
                out_error( "scripts.lua: syntax error in script '", scriptname, "': ", err )
            else
                local bol, ret = pcall( ret )
                if not bol then
                    out_error( "scripts.lua: lua error in script '", scriptname, "': ", ret )
                else
                    _loaded[ scriptname ] = ret
                    _scripts[ key ] = scriptname
                end
            end
        end
    end
    firelistener "onStart"
end

killscripts = function( )
    firelistener "onExit"
    _loaded = { }
    _scripts = { }
    _listeners = { }
    _len = 0
    mem_free( )
end

import = function( script )
    script = tostring( script )
    local tbl = _loaded[ script ] or _loaded[ script .. ".lua" ]
    if type( tbl ) == "table" then
        local ctbl = { }
        for i, k in pairs( tbl ) do
            ctbl[ i ] = k
        end
        return setmetatable( ctbl, { __mode = "v" } )
    else
        return tbl
    end
end

init = function( )
    out.setlistener( "error", function( msg ) firelistener( "onError", tostring( msg ) ) end )
end

----------------------------------// BEGIN //--

----------------------------------// PUBLIC INTERFACE //--

return {

    init = init,

    kill = killscripts,
    start = startscripts,
    import = import,
    firelistener = firelistener,

}
