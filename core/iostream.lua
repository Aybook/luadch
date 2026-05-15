--[[

        iostream.lua - Phase 8 IO layer, steps S1 + S2

        Per-connection inbound framing, extracted out of server.lua so
        the server loop no longer relies on LuaSocket's "*l" line
        pattern. server.lua reads raw bytes and feeds them to a
        per-connection PIPELINE; the pipeline reassembles them into
        newline-delimited ADC frames across reads (the buffer LuaSocket
        used to own internally now lives here).

        S2 generalises the S1 fixed framer into a composable pipeline of
        STAGES. This is a behaviour-neutral proof step: the default
        pipeline is exactly one stage (the ADC-line framer carrying the
        S1 logic verbatim), so a 1-stage pipeline is byte-for-byte
        identical to the old framer. The seam exists so later steps slot
        in as stages without touching server.lua again:

          - S3 HTTP: an HTTP framer stage (bytes -> request units)
          - S4 ZLIF: an inflate stage prepended ahead of the ADC-line
            stage on ZON (bytes -> decompressed bytes)
          - S5 BLOM: a counted-binary capture stage

        Stage contract:

            stage:push( chunk ) -> units, overflow

          - `chunk`    : a byte string from the previous stage (raw
                         socket bytes for stage 1).
          - `units`    : ordered array of whatever this stage emits.
                         The ADC-line stage emits complete frame
                         strings (each WITHOUT the terminating "\n" and
                         with every "\r" dropped, exactly as LuaSocket
                         "*l" recvline does - see below). A passthrough
                         stage re-emits its input as a single unit.
          - `overflow` : bool; only a framing/terminal stage sets it
                         (size-cap breach -> caller closes the
                         connection, mirroring the old
                         `len > maxreadlen` guard).

        Pipeline contract (unchanged from S1's framer so server.lua is
        a ~2-line change):

            pipeline:feed( bytes ) -> frames, overflow

        ADC-line stage CR handling: LuaSocket "*l" recvline
        (luasocket/src/buffer.c:231-234, "we ignore all \r's") strips
        EVERY "\r" in the line, not just a trailing one. ADC is
        "\n"-only and the Phase-7 parser rejects embedded CR, so
        stripping only a trailing CR would flip a previously-accepted
        "a\rb" line into a hard parser reject - a real behaviour
        change. S1/S2 reproduce "*l"'s strip-all-CR verbatim.

        No sockets, no IO, no globals here - pure byte -> unit logic so
        every stage is unit-testable in isolation.

]]--

----------------------------------// DECLARATION //--

local use = use

local string = use "string"
local setmetatable = use "setmetatable"

local string_find = string.find
local string_sub = string.sub
local string_gsub = string.gsub
local string_len = string.len

local newadclinestage
local newpassthroughstage
local newpipeline

----------------------------------// DEFINITION //--

-- ADC-line framer stage. Holds the cross-push unterminated remainder
-- in a closure. Logic is the S1 framer verbatim (so the default
-- 1-stage pipeline is byte-identical to S1).
newadclinestage = function( maxlen )

    local buf = ""

    local push = function( _, chunk )
        local units, n = { }, 0
        local overflow = false

        if chunk and chunk ~= "" then
            buf = buf .. chunk
        end

        local startpos = 1
        while true do
            local nlpos = string_find( buf, "\n", startpos, true )    -- plain find, no patterns
            if not nlpos then
                break
            end
            -- take bytes up to (not including) "\n", then drop EVERY
            -- "\r" (recvline ignores all CRs in the line).
            local frame = ( string_gsub( string_sub( buf, startpos, nlpos - 1 ), "\r", "" ) )
            if string_len( frame ) > maxlen then
                overflow = true
            end
            n = n + 1
            units[ n ] = frame
            startpos = nlpos + 1
        end

        if startpos > 1 then
            buf = string_sub( buf, startpos )
        end
        if string_len( buf ) > maxlen then
            overflow = true
        end

        return units, overflow
    end

    return setmetatable( { }, { __index = { push = push } } )

end    -- newadclinestage

-- Passthrough stage: re-emits its input chunk as a single unit,
-- stateless, never overflows. Identity element for pipeline
-- composition; `[passthrough, adcline]` behaves exactly like
-- `[adcline]`.
newpassthroughstage = function( )

    local push = function( _, chunk )
        return { chunk }, false
    end

    return setmetatable( { }, { __index = { push = push } } )

end    -- newpassthroughstage

-- newpipeline( maxlen ) -> pipeline object.
--
--   pipeline:feed( bytes ) -> frames, overflow
--       runs bytes through stage 1, its units through stage 2, ... ;
--       the terminal stage's units are the dispatchable ADC frames.
--       `overflow` is the OR of every stage's overflow signal.
--
--   pipeline:prepend( stage )
--       insert a stage at the FRONT (the rebuild seam: S4's ZON
--       handler splices an inflate stage ahead of the ADC-line stage
--       mid-stream). Defined here, first exercised in S4.
--
-- The default pipeline is a single ADC-line stage, so feed() is
-- byte-for-byte identical to S1's framer (one consumer: server.lua).
newpipeline = function( maxlen )

    local stages = { newadclinestage( maxlen ) }

    local feed = function( _, bytes )
        local units = { bytes or "" }
        local overflow = false
        for s = 1, #stages do
            local stage = stages[ s ]
            local out, m = { }, 0
            for u = 1, #units do
                local produced, ov = stage:push( units[ u ] )
                if ov then
                    overflow = true
                end
                for i = 1, #produced do
                    m = m + 1
                    out[ m ] = produced[ i ]
                end
            end
            units = out
        end
        return units, overflow
    end

    local prepend = function( _, stage )
        local shifted = { stage }
        for i = 1, #stages do
            shifted[ i + 1 ] = stages[ i ]
        end
        stages = shifted
    end

    return setmetatable( { }, { __index = { feed = feed, prepend = prepend } } )

end    -- newpipeline

----------------------------------// PUBLIC INTERFACE //--

return {

    newpipeline         = newpipeline,
    newadclinestage     = newadclinestage,
    newpassthroughstage = newpassthroughstage,

}
