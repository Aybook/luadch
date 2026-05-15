--[[

        iostream.lua - Phase 8 IO layer, step 1

        Per-connection inbound framing, extracted out of server.lua so the
        server loop no longer relies on LuaSocket's "*l" line pattern to
        cut ADC frames for it. server.lua now reads raw bytes and hands
        them here; this module reassembles them into newline-delimited
        ADC frames across reads (the buffer LuaSocket used to own
        internally now lives in our process, which is what later steps -
        HTTP framing, ZLIF inflate, BLOM counted-binary - need).

        S1 scope: ADC-line framer ONLY. Behaviour is intentionally
        identical to the previous `receive( socket, "*l" )` path:

          - a frame is the bytes up to (not including) a "\n";
          - EVERY "\r" in the frame is dropped, exactly as LuaSocket
            "*l" does (luasocket/src/buffer.c:231-234 recvline: "we
            ignore all \r's" - it strips every CR in the line, not just
            a trailing one). ADC is "\n"-only and the Phase-7 parser
            rejects embedded CR, so stripping only a trailing CR would
            flip a previously-accepted "a\rb" line into a hard parser
            reject - a real behaviour change. S1 must be neutral, so it
            reproduces "*l"'s strip-all-CR behaviour verbatim;
          - an empty line yields "" (hub.lua's incoming() already skips
            data == "", unchanged);
          - the unterminated remainder is kept for the next feed();
          - if the pending unterminated buffer, or any single extracted
            frame, exceeds maxlen, overflow is signalled so the caller
            can close the connection exactly like the old
            `len > maxreadlen` guard did (Phase-7 oversize protection).

        No sockets, no IO, no globals here - pure byte -> frame logic so
        it is unit-testable and reusable by every later pipeline stage.

]]--

----------------------------------// DECLARATION //--

local use = use

local string = use "string"
local setmetatable = use "setmetatable"

local string_find = string.find
local string_sub = string.sub
local string_gsub = string.gsub
local string_len = string.len

local newframer

----------------------------------// DEFINITION //--

-- newframer( maxlen ) -> framer object with one method:
--
--   framer:feed( chunk ) -> frames, overflow
--
--     frames   : array (possibly empty) of complete ADC frames, in
--                order, each WITHOUT the terminating "\n" (and without a
--                single trailing "\r" if one was present), exactly the
--                strings the old "*l" path produced.
--     overflow : true if the pending unterminated buffer or any single
--                returned frame exceeded maxlen. The caller must then
--                close the connection (mirrors server.lua's old
--                "receive buffer exceeded" path). Frames decoded before
--                the offending oversize one are still returned so the
--                caller can dispatch them first, matching how the old
--                multi-call "*l" path dispatched earlier valid lines
--                before hitting the oversize one.
--
-- The framer holds the cross-read remainder in a closure; one framer
-- per connection, created in server.lua's wrapconnection().

newframer = function( maxlen )

    local buf = ""

    local feed = function( _, chunk )
        local frames, n = { }, 0
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
            -- mirror LuaSocket "*l" exactly: take bytes up to (not
            -- including) "\n", then drop EVERY "\r" (recvline ignores
            -- all CRs in the line, not just a trailing one).
            local frame = ( string_gsub( string_sub( buf, startpos, nlpos - 1 ), "\r", "" ) )
            if string_len( frame ) > maxlen then
                overflow = true
            end
            n = n + 1
            frames[ n ] = frame
            startpos = nlpos + 1
        end

        -- keep only the unterminated remainder
        if startpos > 1 then
            buf = string_sub( buf, startpos )
        end
        if string_len( buf ) > maxlen then
            overflow = true
        end

        return frames, overflow
    end

    return setmetatable( { }, { __index = { feed = feed } } )

end    -- newframer

----------------------------------// PUBLIC INTERFACE //--

return {

    newframer = newframer,

}
