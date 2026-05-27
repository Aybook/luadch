--[[

    tests/unit/http_filter_test.lua

    Unit tests for core/http_filter.lua (#264). The smoke harness
    exercises the wire-up of each list endpoint (substring match +
    one unknown-field 400); this file covers the helper itself:
    string / integer / boolean / date filter semantics, sort
    direction, pagination clamping, unknown-field rejection, and
    error envelopes. Added as part of #275 COV-7.

    Run: lua5.4 tests/unit/http_filter_test.lua
    Exit 0 = all pass, 1 = a failure.

]]--

-- `use` shim - http_filter.lua only touches stdlib + lua built-ins.
local _real = {
    type = type, ipairs = ipairs, pairs = pairs,
    tonumber = tonumber, tostring = tostring,
    table = table, string = string, math = math,
}
_G.use = function( name )
    local v = _real[ name ]
    assert( v ~= nil, "http_filter_test shim missing dep: use \"" .. name .. "\"" )
    return v
end

local hf = assert( loadfile( "core/http_filter.lua" ) )( )

local failures, checks = 0, 0
local function eq( label, got, want )
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        io.write( string.format( "FAIL %-60s got=%q want=%q\n",
            label, tostring( got ), tostring( want ) ) )
    else
        io.write( string.format( "ok   %s\n", label ) )
    end
end

local function deep_eq( label, got, want )
    -- shallow array-of-primitives compare (enough for our use)
    checks = checks + 1
    if type( got ) ~= type( want ) then
        failures = failures + 1
        io.write( string.format( "FAIL %-60s type mismatch got=%s want=%s\n",
            label, type( got ), type( want ) ) )
        return
    end
    if type( want ) == "table" then
        if #got ~= #want then
            failures = failures + 1
            io.write( string.format( "FAIL %-60s len got=%d want=%d\n",
                label, #got, #want ) )
            return
        end
        for i = 1, #want do
            if got[ i ] ~= want[ i ] then
                failures = failures + 1
                io.write( string.format( "FAIL %-60s [%d] got=%q want=%q\n",
                    label, i, tostring( got[ i ] ), tostring( want[ i ] ) ) )
                return
            end
        end
    end
    io.write( string.format( "ok   %s\n", label ) )
end

----------------------------------------------------------------------
-- Sample dataset + spec mirroring real /v1/registered usage.
----------------------------------------------------------------------

local rows = {
    { nick = "alice",   level = 20, active = true,  regged = "2026-01-01 / 00:00:00" },
    { nick = "bob",     level = 50, active = false, regged = "2026-02-15 / 00:00:00" },
    { nick = "carol",   level = 50, active = true,  regged = "2026-03-10 / 00:00:00" },
    { nick = "dave",    level = 100, active = true, regged = "2026-04-01 / 00:00:00" },
    { nick = "Eve",     level = 30, active = false, regged = nil },  -- nil date intentional
}

-- Spec mirrors the real cmd_reg / cmd_ban / etc_*manager shapes:
-- string_fields / integer_fields / boolean_fields map name -> bare
-- getter function. ONLY date_fields uses the {get, parse_query}
-- table shape (it needs the per-spec query-parser).
local spec = {
    string_fields  = { nick   = function( r ) return r.nick end },
    integer_fields = { level  = function( r ) return r.level end },
    boolean_fields = { active = function( r ) return r.active end },
    date_fields    = {
        regged = {
            get = function( r ) return r.regged end,
            parse_query = function( q )
                -- accept "YYYY-MM-DD / HH:MM:SS"; reject anything else
                if not q:match( "^%d%d%d%d%-%d%d%-%d%d / %d%d:%d%d:%d%d$" ) then
                    return nil, "expected YYYY-MM-DD / HH:MM:SS"
                end
                return q
            end,
        },
    },
    sortable_fields = {
        nick  = function( r ) return r.nick end,
        level = function( r ) return r.level end,
    },
    default_sort_field = "nick",
    default_sort_descending = false,
}

----------------------------------------------------------------------
-- No-filter / no-sort / default pagination
----------------------------------------------------------------------

do
    local ok, page, pag = hf.apply( { }, spec, rows )
    eq( "no-filter: ok", ok, true )
    eq( "no-filter: total", pag.total, 5 )
    eq( "no-filter: limit defaults to 200", pag.limit, 200 )
    eq( "no-filter: offset 0", pag.offset, 0 )
    eq( "no-filter: returns all rows", #page, 5 )
    -- default sort = nick ascending; "Eve" < "alice" by byte order
    -- (uppercase E = 0x45 < lowercase a = 0x61); document the byte-
    -- compare behaviour.
    eq( "no-filter: default-sort first row", page[ 1 ].nick, "Eve" )
end

----------------------------------------------------------------------
-- String substring filter
----------------------------------------------------------------------

do
    local ok, page = hf.apply( { nick = "a" }, spec, rows )
    eq( "string-filter: ok", ok, true )
    -- substring "a" matches alice (a), carol (a), dave (a). NOT Eve.
    eq( "string-filter: matches", #page, 3 )
end

do
    local ok, page = hf.apply( { nick = "zzz_no_match" }, spec, rows )
    eq( "string-filter: no matches ok", ok, true )
    eq( "string-filter: no matches len", #page, 0 )
end

----------------------------------------------------------------------
-- Integer exact / _min / _max
----------------------------------------------------------------------

do
    local ok, page = hf.apply( { level = "50" }, spec, rows )
    eq( "int-exact: ok", ok, true )
    eq( "int-exact: matches", #page, 2 )    -- bob + carol
end

do
    local ok, page = hf.apply( { level_min = "30", level_max = "60" }, spec, rows )
    eq( "int-range: ok", ok, true )
    -- 30, 50, 50 -> Eve, bob, carol
    eq( "int-range: count", #page, 3 )
end

do
    -- Bad integer bound -> 400 + named error
    local ok, status, code, msg = hf.apply( { level_min = "notanumber" }, spec, rows )
    eq( "int-bad: ok flag", ok, false )
    eq( "int-bad: status 400", status, 400 )
    eq( "int-bad: code", code, "E_BAD_INPUT" )
    eq( "int-bad: msg contains field name",
        string.find( msg or "", "level_min", 1, true ) ~= nil, true )
end

----------------------------------------------------------------------
-- Boolean
----------------------------------------------------------------------

do
    local ok, page = hf.apply( { active = "true" }, spec, rows )
    eq( "bool-true: ok", ok, true )
    eq( "bool-true: matches", #page, 3 )    -- alice + carol + dave
end

do
    local ok, page = hf.apply( { active = "false" }, spec, rows )
    eq( "bool-false: matches", #page, 2 )   -- bob + Eve
end

----------------------------------------------------------------------
-- Date _after / _before + nil-date stays out of result
----------------------------------------------------------------------

do
    local ok, page = hf.apply(
        { regged_after = "2026-02-01 / 00:00:00" }, spec, rows )
    eq( "date-after: ok", ok, true )
    -- bob, carol, dave keep; alice + Eve (nil) drop.
    eq( "date-after: count", #page, 3 )
    -- nil-date row MUST NOT pass any range filter
    for _, r in ipairs( page ) do
        if r.nick == "Eve" then
            failures = failures + 1
            io.write( "FAIL date-after: Eve (nil-date) leaked into filtered result\n" )
        end
    end
end

do
    local ok, page = hf.apply(
        { regged_before = "2026-02-20 / 00:00:00" }, spec, rows )
    eq( "date-before: count (alice + bob, NOT Eve nil-date)", #page, 2 )
end

do
    local ok, status, code, msg = hf.apply(
        { regged_after = "garbage" }, spec, rows )
    eq( "date-bad: ok false", ok, false )
    eq( "date-bad: status 400", status, 400 )
    eq( "date-bad: code", code, "E_BAD_INPUT" )
end

----------------------------------------------------------------------
-- Sort
----------------------------------------------------------------------

do
    local ok, page = hf.apply( { sort = "level" }, spec, rows )
    eq( "sort-asc: ok", ok, true )
    eq( "sort-asc: first level", page[ 1 ].level, 20 )
    eq( "sort-asc: last level", page[ #page ].level, 100 )
end

do
    local ok, page = hf.apply( { sort = "-level" }, spec, rows )
    eq( "sort-desc: first level", page[ 1 ].level, 100 )
    eq( "sort-desc: last level", page[ #page ].level, 20 )
end

----------------------------------------------------------------------
-- Pagination
----------------------------------------------------------------------

do
    local ok, page, pag = hf.apply( { limit = "2", offset = "1" }, spec, rows )
    eq( "page: ok", ok, true )
    eq( "page: total still 5", pag.total, 5 )
    eq( "page: limit 2", pag.limit, 2 )
    eq( "page: offset 1", pag.offset, 1 )
    eq( "page: returns 2 rows", #page, 2 )
    eq( "page: next_offset", pag.next_offset, 3 )
end

do
    local ok, page, pag = hf.apply( { limit = "100", offset = "10" }, spec, rows )
    eq( "page: offset past total", #page, 0 )
    eq( "page: total still 5", pag.total, 5 )
    eq( "page: next_offset nil at end", pag.next_offset, nil )
end

do
    local ok, page, pag = hf.apply( { limit = "0" }, spec, rows )
    eq( "page: limit 0 clamps to 1", pag.limit, 1 )
end

do
    -- Default max_limit is 1000; 5000 should clamp.
    local ok, page, pag = hf.apply( { limit = "5000" }, spec, rows )
    eq( "page: limit huge clamps to 1000", pag.limit, 1000 )
end

----------------------------------------------------------------------
-- Unknown filter field -> 400
----------------------------------------------------------------------

do
    local ok, status, code, msg = hf.apply(
        { bogus_field_xyz = "42" }, spec, rows )
    eq( "unknown-field: ok false", ok, false )
    eq( "unknown-field: status 400", status, 400 )
    eq( "unknown-field: code", code, "E_BAD_INPUT" )
    -- allowed-fields hint should mention 'nick' (a real spec field)
    eq( "unknown-field: hint mentions allowed fields",
        string.find( msg or "", "nick", 1, true ) ~= nil, true )
end

----------------------------------------------------------------------
-- Unknown sort field -> 400
----------------------------------------------------------------------

do
    local ok, status, code = hf.apply( { sort = "bogus_sort_field" }, spec, rows )
    eq( "unknown-sort: ok false", ok, false )
    eq( "unknown-sort: status 400", status, 400 )
    eq( "unknown-sort: code", code, "E_BAD_INPUT" )
end

----------------------------------------------------------------------
-- Input mutation safety: apply returns a fresh array; sorting must
-- NOT reorder the caller's `rows` table.
----------------------------------------------------------------------

do
    local original_first = rows[ 1 ].nick
    hf.apply( { sort = "-level" }, spec, rows )
    eq( "no-mutation: rows[1] unchanged after sort",
        rows[ 1 ].nick, original_first )
end

----------------------------------------------------------------------

io.write( string.format( "\n%d checks, %d failures\n", checks, failures ) )
os.exit( failures == 0 and 0 or 1 )
