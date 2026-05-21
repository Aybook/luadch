--[[

    tests/unit/bloom_test.lua

    Committed unit test for core/bloom.lua (Phase 8 S5 ADC-EXT BLOM).
    Pure Lua, no hub, no sockets: stubs the `use` sandbox shim, loads
    the module, asserts the membership-oracle contract.

    Run: lua tests/unit/bloom_test.lua   (any Lua 5.4)
    Exit code 0 = all pass, 1 = a failure (CI-friendly).

    CI wiring: same .github/workflows/smoke.yml Linux step as the
    iostream unit test (lua5.4 against pure-Lua module files).

]]--

-- sandbox shim. bloom.lua's `use` imports are string + setmetatable.
local _real = {
    string = string,
    setmetatable = setmetatable,
}
_G.use = function( name )
    local v = _real[ name ]
    assert( v ~= nil, "bloom_test shim missing dep: use \"" .. name .. "\"" )
    return v
end

local bloom = assert( loadfile( "core/bloom.lua" ) )( )

local failures, checks = 0, 0
local function eq( label, got, want )
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        io.write( string.format( "FAIL %-44s got=%q want=%q\n", label, tostring( got ), tostring( want ) ) )
    else
        io.write( string.format( "ok   %s\n", label ) )
    end
end

-- Construct a 24-byte (192-bit) TTH from a Lua-string seed using a
-- trivial repeat-of-bytes generator. NOT cryptographically anything;
-- we only need deterministic, distinct 24-byte values.
local function tth( seed )
    local s = {}
    for i = 1, 24 do
        s[ i ] = string.char( ( seed * 31 + i * 17 ) % 256 )
    end
    return table.concat( s )
end

-- Insert a single TTH into a filter byte string. Uses the same
-- bit-extraction formula as bloom.contains so the test acts as an
-- oracle: every inserted TTH must subsequently :contains() true.
local function insert( filter_bytes, tth_bytes, k, h, m )
    local bytes_per_slice = h // 8
    local bits = { }
    for i = 1, #filter_bytes do
        bits[ i ] = string.byte( filter_bytes, i )
    end
    for i = 0, k - 1 do
        local offset = i * bytes_per_slice
        local pos = 0
        for j = 0, bytes_per_slice - 1 do
            pos = pos | ( string.byte( tth_bytes, offset + j + 1 ) << ( 8 * j ) )
        end
        pos = pos % m
        local byte_idx = ( pos >> 3 ) + 1
        bits[ byte_idx ] = bits[ byte_idx ] | ( 1 << ( pos & 7 ) )
    end
    local chunks = { }
    for i = 1, #bits do chunks[ i ] = string.char( bits[ i ] ) end
    return table.concat( chunks )
end

----------------------------------------------------------------------
-- Basic shape: empty filter, no element matches.
----------------------------------------------------------------------

do
    local m, k, h = 4096, 6, 16    -- 512-byte filter
    local empty = string.rep( "\0", m / 8 )
    local f = bloom.newfilter( empty, k, h, m )
    eq( "empty filter: random TTH not contained", f:contains( tth( 7 ) ), false )
    eq( "empty filter: another TTH not contained", f:contains( tth( 42 ) ), false )
    eq( "empty filter: rejects short input",       f:contains( "tooShort" ), false )
end

----------------------------------------------------------------------
-- Insert / lookup roundtrip: every inserted TTH must come back true.
-- This is the "no false negatives" invariant - the entire point of
-- a bloom filter as a routing oracle.
----------------------------------------------------------------------

do
    local m, k, h = 4096, 6, 16
    local f_bytes = string.rep( "\0", m / 8 )
    local inserted = { tth( 1 ), tth( 2 ), tth( 3 ), tth( 100 ), tth( 12345 ) }
    for _, t in ipairs( inserted ) do
        f_bytes = insert( f_bytes, t, k, h, m )
    end
    local f = bloom.newfilter( f_bytes, k, h, m )
    for i, t in ipairs( inserted ) do
        eq( "roundtrip: inserted TTH #" .. i .. " contained", f:contains( t ), true )
    end
end

----------------------------------------------------------------------
-- False-positive sanity. With m=32768, k=6, h=16 and only 5
-- elements inserted, querying 200 distinct uninserted TTHs should
-- give zero or very few positives. (Theoretical FPR at n=5 is
-- vanishingly small.)
----------------------------------------------------------------------

do
    local m, k, h = 32768, 6, 16
    local f_bytes = string.rep( "\0", m / 8 )
    local inserted_set = { }
    for i = 1, 5 do
        local t = tth( i )
        f_bytes = insert( f_bytes, t, k, h, m )
        inserted_set[ t ] = true
    end
    local f = bloom.newfilter( f_bytes, k, h, m )
    local positives = 0
    for i = 1000, 1199 do
        local t = tth( i )
        if not inserted_set[ t ] and f:contains( t ) then
            positives = positives + 1
        end
    end
    if positives > 5 then
        failures = failures + 1
        io.write( string.format( "FAIL  false-positive sanity (n=5, m=32768, k=6, h=16): got %d/200 positives, expected <= 5\n", positives ) )
    else
        io.write( string.format( "ok   false-positive sanity (%d/200 positives, n=5, m=32768)\n", positives ) )
    end
    checks = checks + 1
end

----------------------------------------------------------------------
-- Different `h` values exercise the byte-slicing for both 8-bit and
-- 24-bit slice widths (spec restriction is h % 8 == 0).
----------------------------------------------------------------------

do
    local m, k, h = 4096, 6, 8
    local f_bytes = string.rep( "\0", m / 8 )
    local t = tth( 99 )
    f_bytes = insert( f_bytes, t, k, h, m )
    local f = bloom.newfilter( f_bytes, k, h, m )
    eq( "h=8: roundtrip works", f:contains( t ), true )
end

do
    local m, k, h = 524288, 6, 24    -- 64 KiB filter, 192 bit-slice (max k*h=144)
    local f_bytes = string.rep( "\0", m / 8 )
    local t = tth( 314 )
    f_bytes = insert( f_bytes, t, k, h, m )
    local f = bloom.newfilter( f_bytes, k, h, m )
    eq( "h=24: roundtrip works", f:contains( t ), true )
end

----------------------------------------------------------------------
-- Distinguishability: a TTH whose bits are guaranteed not all set
-- in the filter should not match. Construct a filter with exactly
-- one TTH inserted, then probe with TTHs whose first slice bit is
-- guaranteed different.
----------------------------------------------------------------------

do
    local m, k, h = 4096, 6, 16
    local f_bytes = string.rep( "\0", m / 8 )
    local t = tth( 1 )
    f_bytes = insert( f_bytes, t, k, h, m )
    local f = bloom.newfilter( f_bytes, k, h, m )
    eq( "distinguishability: inserted TTH contained", f:contains( t ), true )
    -- Probe with shifted TTHs and ensure most are NOT contained.
    -- We accept a few false positives but require the majority to
    -- be filtered out.
    local rejected = 0
    for i = 100, 150 do
        if not f:contains( tth( i ) ) then
            rejected = rejected + 1
        end
    end
    if rejected < 40 then
        failures = failures + 1
        io.write( string.format( "FAIL  distinguishability sanity: only %d/51 probes rejected (expected most)\n", rejected ) )
    else
        io.write( string.format( "ok   distinguishability sanity (%d/51 probes rejected)\n", rejected ) )
    end
    checks = checks + 1
end

----------------------------------------------------------------------

io.write( string.format( "\n%d checks, %d failures\n", checks, failures ) )
os.exit( failures == 0 and 0 or 1 )
