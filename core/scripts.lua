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
local os = use "os"
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
-- Removed across Tier-2 sub-PRs (cumulative):
--   require    Sub-PR-1: plugins now reach modules through
--              whitelisted globals (`ssl`, `basexx`); ssl submodules
--              like `ssl.x509` are pre-attached in core/init.lua so
--              `local x509 = ssl.x509` replaces `require "ssl.x509"`
--   package    Sub-PR-1: cmd_hubinfo's old `package.config:sub(1,1)`
--              is replaced by `util.path_sep()` so the whole
--              `package` library no longer leaks into the sandbox
--   os         Sub-PR-2: replaced by a curated `_os_safe` shim
--              exposing ONLY os.time / os.date / os.difftime
--              (the only os methods the 66-plugin audit found in
--              use). Blocks os.execute / os.remove / os.rename /
--              os.exit / os.setlocale / os.tmpname / os.tmpfile /
--              os.getenv reachability from plugin code.
--   io         Sub-PR-3: replaced by a curated `_io_safe` shim
--              exposing ONLY io.open with path-restriction (no
--              absolute paths, no parent-dir traversal). Blocks
--              io.popen entirely; cmd_hubinfo's old system-info
--              io.popen calls migrated to the new
--              `core/sysinfo.lua` core module (whitelisted as
--              `sysinfo`). Closes the last major sandbox-escape
--              vector identified in #206.

-- Curated `os` shim for the plugin sandbox (#206 Tier-2 Sub-PR-2).
-- Plugin code that needs current-time / date-format / time-arithmetic
-- reaches the same Lua-stdlib functions, but the dangerous siblings
-- on the os table (execute / remove / rename / exit / tmpname /
-- tmpfile / setlocale / getenv) are not in this table - access to
-- env.os.execute returns nil + the next `.execute(...)` errors
-- with "attempt to call a nil value (method 'execute')". Adding a
-- method here requires a security review of every plugin that
-- gets exposed to it (Tier-2 Sub-PR-3 follows the same pattern
-- for `io`).
local _os_safe = {
    time     = os.time,
    date     = os.date,
    difftime = os.difftime,
}

-- Curated `io` shim for the plugin sandbox (#206 Tier-2 Sub-PR-3).
-- `io.popen` is no longer in the shim - the only legitimate caller
-- (`cmd_hubinfo` for system-info detection) now reaches the curated
-- core helper `sysinfo` instead. `io.open` is path-restricted:
-- absolute paths and parent-dir traversal are rejected so a
-- compromised plugin can't read `/etc/shadow`, `C:\Windows\…`,
-- or escape its working dir via `../../`. Bundled plugins write
-- to relative paths under `log/`, `cfg/`, `certs/`, `scripts/data/`
-- - all permitted.
--
-- NOT in the shim (left absent on purpose):
--   io.popen        shell-arbitrary-command via pipe
--   io.input        replaces the process-global stdin handle
--   io.output       replaces the process-global stdout handle
--   io.read         reads from the current process-global input
--   io.write        writes to the current process-global output
--   io.stdin / stdout / stderr   plugin should not touch the
--                                 hub's tty handles
--   io.lines        relies on io.input / io.open semantics
--   io.tmpfile      tempfile handle
--   io.close        no-op without io.open's matching handle
--   io.type         introspection of file handles
--
-- The file handle returned by `_io_safe.open` IS the real Lua
-- file handle (same userdata) - its methods (`:read`, `:write`,
-- `:close`, `:lines`, `:seek`, `:setvbuf`) work normally. The
-- shim only narrows the entry point.
local _io_safe = {
    open = function( path, mode )
        if type( path ) ~= "string" then
            return nil, "io_safe: path must be a string"
        end
        -- Reject absolute POSIX paths ("/..."), absolute Windows
        -- paths ("C:\..." / "C:/..." / "\\\\server\\..."), and
        -- parent-dir traversal anywhere in the string. The
        -- restriction is intentionally conservative; the bundled
        -- plugins use only relative paths like "log/error.log",
        -- "cfg/cfg.tbl", "certs/cert.pem", "scripts/data/<x>.tbl".
        local first = path:sub( 1, 1 )
        if first == "/" or first == "\\" then
            return nil, "io_safe: absolute paths blocked (got '" .. path .. "')"
        end
        if path:match( "^[A-Za-z]:[/\\]" ) then
            return nil, "io_safe: absolute Windows paths blocked (got '" .. path .. "')"
        end
        -- Block parent-dir traversal: reject if ANY path component
        -- (between `/` or `\` separators) is exactly "..". This
        -- catches `..`, `../foo`, `foo/..`, `foo/../bar`,
        -- `log\..\etc\shadow` etc. while ALLOWING legitimate
        -- filenames that happen to contain two consecutive dots
        -- (`thesis..v2.lua`, `foo..bar`) - the earlier
        -- `path:find("%.%.")` check produced false positives on
        -- those. A single dot `.` (current dir) stays allowed
        -- because `.` isn't a traversal escape.
        for component in path:gmatch( "[^/\\]+" ) do
            if component == ".." then
                return nil, "io_safe: parent-dir traversal blocked (got '" .. path .. "')"
            end
        end
        return io.open( path, mode )
    end,
}
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
    -- `os` and `io` were here until Tier-2 Sub-PR-2 / Sub-PR-3
    -- replaced them with curated `_os_safe` / `_io_safe` shims
    -- (assigned to env.os / env.io explicitly after the
    -- SANDBOX_GLOBALS loop runs).
    -- `sysinfo` is the new core module that owns the host-OS /
    -- CPU / RAM detection - cmd_hubinfo calls into it instead of
    -- shelling out via io.popen directly.
    "sysinfo",
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
            -- Curated `os` shim (#206 Tier-2 Sub-PR-2). Replaces
            -- the full `os` library so plugin code reaches only
            -- the three methods the bundled-plugin audit found in
            -- use (time / date / difftime). See `_os_safe`
            -- definition near the SANDBOX_GLOBALS block above.
            env.os = _os_safe
            -- Curated `io` shim (#206 Tier-2 Sub-PR-3). io.popen
            -- is gone; io.open is path-restricted. See `_io_safe`.
            env.io = _io_safe
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
