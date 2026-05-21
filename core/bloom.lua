--[[

        bloom.lua - Phase 8 S5 ADC-EXT BLOM bloom filter (#147 T2.2).

        Pure-Lua membership oracle for the per-user filter the hub
        receives from a client via HSND. The hub consults it in the
        BSCH / FSCH router on every HASH-search (SCH with `TR`) so
        the hash-search is forwarded only to clients whose filter
        could match.

        Spec (ADC-EXT 3.20):

          For each of k iterations, read h bits starting at bit
          offset i*h from the (192-bit, 24-byte) TTH, interpret as
          little-endian unsigned integer, modulo m to get a bit
          index into the m-bit filter. The element is "possibly
          present" iff ALL k bits are 1.

        Spec restrictions enforced by the cfg validator (see
        core/cfg_defaults.lua):

          - h % 8 == 0      (byte-aligned slice, spec section 3.20)
          - k * h <= 192    (TTH has only 192 bits to draw from)
          - m % 64 == 0     (filter is 8-byte-word-aligned on the wire)
          - 2^h > m         (the slice index must span the filter)
          - k >= 1

        False-negatives are impossible by construction. False-
        positive rate p = (1 - (1 - 1/m)^(k*n))^k for n inserted
        elements - default params (k=6, h=16, m=32768) give p ~= 39%
        at n=10000 files, which operators tune by raising m for
        larger shares.

        Bit layout in the byte array follows the DC++ convention
        (LSB-first per byte: bit b of byte B sits at byte_array[B]
        & (1 << b)).

]]--

----------------------------------// DECLARATION //--

local use = use

local string = use "string"
local setmetatable = use "setmetatable"

local string_byte = string.byte
local string_len = string.len

local newfilter

----------------------------------// DEFINITION //--

-- newfilter( bytes, k, h, m ) -> filter object.
--
--   bytes : the m/8-byte filter blob received via HSND (Lua string).
--   k, h, m : the bloom parameters the hub negotiated (= the same
--             ones the HGET request carried). The filter object
--             does NOT validate these against the bytes length -
--             that is the caller's job (cfg validator + the HSND
--             handler that constructed this filter).
--
-- filter:contains( tth ) -> bool
--
--   tth   : the 192-bit (24-byte) TTH binary form, i.e. the
--           base32-decoded `TR` named-parameter of a hash-search
--           SCH. Returns true iff the element is "possibly present"
--           in the share - all k filter bits are set. Returns false
--           on length mismatch or when any bit is 0.
newfilter = function( bytes, k, h, m )

    local bytes_per_slice = h // 8    -- spec: h % 8 == 0 enforced by cfg

    local contains = function( _, tth )
        if string_len( tth ) ~= 24 then
            return false
        end
        for i = 0, k - 1 do
            local offset = i * bytes_per_slice
            -- Read h bits as little-endian unsigned int. Spec
            -- example for h=24:
            --   pos = x[0+i*h/8] | (x[1+i*h/8] << 8) | (x[2+i*h/8] << 16)
            -- Generalised below for any h % 8 == 0.
            local pos = 0
            for j = 0, bytes_per_slice - 1 do
                pos = pos | ( string_byte( tth, offset + j + 1 ) << ( 8 * j ) )
            end
            pos = pos % m
            -- Query bit `pos` of `bytes` (LSB-first per byte; DC++
            -- convention).
            local byte_idx = ( pos >> 3 ) + 1    -- 1-based, Lua strings
            local bit_mask = 1 << ( pos & 7 )
            local b_byte = string_byte( bytes, byte_idx )
            if not b_byte or ( b_byte & bit_mask ) == 0 then
                return false
            end
        end
        return true
    end

    return setmetatable( { }, { __index = { contains = contains } } )

end    -- newfilter

----------------------------------// PUBLIC INTERFACE //--

return {

    newfilter = newfilter,

}
