--[[

    tests/unit/iostream_test.lua

    Committed unit test for core/iostream.lua (Phase 8 S1 + S2). Pure
    Lua, no hub, no sockets: stubs the `use` sandbox shim, loads the
    module, asserts the stage/pipeline contract.

    Why this exists: S1/S2 were verified with throwaway scripts, which
    prove nothing for the next person (CLAUDE.md s1a.7). The S2
    pre-merge review flagged the new abstraction surface (passthrough,
    multi-stage fan-in, prepend ordering) as having no committed
    regression - that surface is what S4 (ZLIF inflate spliced ahead of
    the framer via pipeline:prepend) will rely on. This file is the
    durable regression for it.

    Run: lua tests/unit/iostream_test.lua   (any Lua 5.4)
    Exit code 0 = all pass, 1 = a failure (CI-friendly).

    CI wiring: not run by .github/workflows/smoke.yml yet (that harness
    is Python and the build does not emit a standalone lua interpreter).
    The neutral path is already CI-guarded transitively by the S1
    protocol smoke tests (a 1-stage pipeline is byte-identical to the
    S1 framer, so test_s1_fragmented_frame_reassembled /
    test_s1_two_frames_one_segment would break if framing regressed).
    Wiring this file into CI is an explicit gate before S4 lands (see
    docs/phases/PHASE_8_IO.md) - S4 already touches the build for the
    zlib dependency, so the lua-unit runner is in-scope there.

]]--

-- minimal sandbox shim: core/iostream.lua does `local x = use "x"`
local _real = { string = string, table = table, setmetatable = setmetatable }
_G.use = function( name ) return _real[ name ] end

local iostream = assert( loadfile( "core/iostream.lua" ) )( )

local NL, CR, BS = string.char( 10 ), string.char( 13 ), string.char( 92 )

local failures, checks = 0, 0
local function eq( label, got, want )
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        io.write( string.format( "FAIL %-34s got=%q want=%q\n", label, tostring( got ), tostring( want ) ) )
    else
        io.write( string.format( "ok   %s\n", label ) )
    end
end
-- frames array -> single comparable string
local function j( t ) return "[" .. table.concat( t, "|" ) .. "]" end

----------------------------------------------------------------------
-- S1 parity: default 1-stage pipeline must be byte-identical to the
-- old newframer for every input class.
----------------------------------------------------------------------

local p = iostream.newpipeline( 1048576 )
eq( "single frame, escaped body",
    j( ( p:feed( "BMSG AAAA +setpass" .. BS .. "snick" .. BS .. "smyself" .. BS .. "ssmoketestnew" .. NL ) ) ),
    "[BMSG AAAA +setpass\\snick\\smyself\\ssmoketestnew]" )

p = iostream.newpipeline( 1048576 )
eq( "fragmented part 1 -> no frame", j( ( p:feed( "BMSG AAAA +he" ) ) ), "[]" )
eq( "fragmented part 2 -> reassembled", j( ( p:feed( "lp" .. NL ) ) ), "[BMSG AAAA +help]" )

p = iostream.newpipeline( 1048576 )
eq( "two frames one feed",
    j( ( p:feed( "BMSG AAAA +help" .. NL .. "BMSG AAAA +help" .. NL ) ) ),
    "[BMSG AAAA +help|BMSG AAAA +help]" )

p = iostream.newpipeline( 1048576 )
local fr, ov = p:feed( "ABC" .. CR .. NL .. "DEF" .. NL .. "GHI" )
eq( "CRLF stripped + two frames", j( fr ), "[ABC|DEF]" )
eq( "no overflow on normal input", ov, false )
eq( "remainder kept then completed", j( ( p:feed( NL ) ) ), "[GHI]" )

p = iostream.newpipeline( 1048576 )
eq( "embedded CR all stripped (*l recvline parity)",
    j( ( p:feed( "BMSG x he" .. CR .. "ll" .. CR .. "o" .. CR .. NL ) ) ),
    "[BMSG x hello]" )

p = iostream.newpipeline( 8 )
local g, gov = p:feed( "ABCDEFGHIJKL" )    -- 12 byte unterminated > maxlen 8
eq( "oversize unterminated -> overflow", gov, true )
eq( "oversize unterminated -> no frame yet", j( g ), "[]" )

----------------------------------------------------------------------
-- S2 new surface: passthrough, composition, prepend ordering.
----------------------------------------------------------------------

local pt = iostream.newpassthroughstage( )
local u, o = pt:push( "raw" .. NL .. "bytes" )
eq( "passthrough re-emits input as one unit", j( u ), "[raw\nbytes]" )
eq( "passthrough never overflows", o, false )

-- [passthrough, adcline] must behave exactly like [adcline], incl.
-- unterminated-remainder reassembly across feeds.
p = iostream.newpipeline( 1048576 )
p:prepend( iostream.newpassthroughstage( ) )
eq( "compose: frame split, 2nd held",
    j( ( p:feed( "BMSG Z +help" .. NL .. "BMSG Z +x" ) ) ), "[BMSG Z +help]" )
eq( "compose: remainder completes across feed",
    j( ( p:feed( "yz" .. NL ) ) ), "[BMSG Z +xyz]" )

-- prepend must run the new stage BEFORE the framer (the S4
-- inflate-before-framing ordering). A stage that turns 'X' into CR,
-- prepended, must let the framer then strip those CRs.
p = iostream.newpipeline( 1048576 )
local crstage = setmetatable( { }, { __index = { push = function( _, c )
    return { ( c:gsub( "X", CR ) ) }, false
end } } )
p:prepend( crstage )
eq( "prepend ordering: stage runs before framer",
    j( ( p:feed( "aXbXc" .. NL ) ) ), "[abc]" )

----------------------------------------------------------------------

io.write( string.format( "\n%d checks, %d failures\n", checks, failures ) )
os.exit( failures == 0 and 0 or 1 )
