--[[

    tests/unit/usr_share_lang_test.lua

    Lang-key consistency check for scripts/usr_share.lua (#301 PR-2).

    Pre-fix: scripts/usr_share.lua read `lang.msg_minmax`, but
    scripts/lang/usr_share.lang.{de,en} defined the key as
    `msg_sharelimits`. The German translation was therefore DEAD - the
    lookup returned nil, the `or` fallback to the hardcoded English
    literal fired every time, and a German hub showed the English
    message regardless of cfg.language.

    Test: scan the plugin source for every `lang.X` reference and assert
    X exists in BOTH the .lang.de and .lang.en tables. Provably fails on
    the pre-fix code (`lang.msg_minmax` -> nil -> assertion error);
    passes once the lookup is renamed to `lang.msg_sharelimits`.

    Generic-enough that the same pattern can be lifted into a sweeping
    check across all plugins if the broader #301 cleanup wants it.

    Run: lua tests/unit/usr_share_lang_test.lua   (any Lua 5.4)
    Exit code 0 = pass, 1 = failure (CI-friendly).

]]--

local PLUGIN_SOURCE = "scripts/usr_share.lua"
local LANG_DE       = "scripts/lang/usr_share.lang.de"
local LANG_EN       = "scripts/lang/usr_share.lang.en"

local function read_text( path )
    local f, err = io.open( path, "rb" )
    if not f then
        io.stderr:write( "FATAL: cannot open " .. path .. ": " .. tostring( err ) .. "\n" )
        os.exit( 1 )
    end
    local s = f:read( "*a" )
    f:close( )
    return s
end

local function load_lang( path )
    local chunk, err = loadfile( path )
    if not chunk then
        io.stderr:write( "FATAL: cannot load " .. path .. ": " .. tostring( err ) .. "\n" )
        os.exit( 1 )
    end
    local ok, t = pcall( chunk )
    if not ok or type( t ) ~= "table" then
        io.stderr:write( "FATAL: " .. path .. " did not return a table: " .. tostring( t ) .. "\n" )
        os.exit( 1 )
    end
    return t
end

local source = read_text( PLUGIN_SOURCE )
local de     = load_lang( LANG_DE )
local en     = load_lang( LANG_EN )

-- Strip block comments `--[[ ... ]]` and line comments so a stray
-- `lang.X` in a comment cannot trip a false positive.
local function strip_comments( s )
    s = s:gsub( "%-%-%[%[.-%]%]", "" )
    s = s:gsub( "%-%-[^\n]*", "" )
    return s
end
source = strip_comments( source )

-- Collect every `lang.X` reference. Lua identifier = [A-Za-z_][A-Za-z0-9_]*.
local refs = { }
for key in source:gmatch( "lang%.([%w_]+)" ) do
    refs[ key ] = true
end

local failures, checks = 0, 0
local function check( label, ok )
    checks = checks + 1
    if not ok then
        failures = failures + 1
        io.write( "FAIL " .. label .. "\n" )
    else
        io.write( "ok   " .. label .. "\n" )
    end
end

-- The reference set must be non-empty - otherwise the test is vacuous
-- (a refactor that drops every lang.X lookup would make the assertions
-- below trivially pass).
local n = 0; for _ in pairs( refs ) do n = n + 1 end
check( "found at least one lang.X reference in " .. PLUGIN_SOURCE, n > 0 )

for key in pairs( refs ) do
    check( "de[" .. key .. "] defined",
           type( de[ key ] ) == "string" and de[ key ] ~= "" )
    check( "en[" .. key .. "] defined",
           type( en[ key ] ) == "string" and en[ key ] ~= "" )
end

io.write( string.format( "\n%d/%d checks passed (%d lang.X reference(s) scanned)\n",
                         checks - failures, checks, n ) )
if failures > 0 then
    io.write( "FAIL " .. failures .. " check(s) failed\n" )
    os.exit( 1 )
end
io.write( "OK usr_share_lang_test\n" )
