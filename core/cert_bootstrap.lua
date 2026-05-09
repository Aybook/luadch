--[[

    cert_bootstrap.lua - first-boot TLS cert auto-generation (#77).

    When TLS-only is the default (Phase 7-style hardening), shipping a
    fresh install with no servercert.pem leaves the operator with a
    boot-time error and a manual `certs/make_cert.{sh,bat}` step. This
    module closes that gap: on hub start, if certs/serverkey.pem and
    certs/servercert.pem are missing, generate a self-signed P-256
    ECDSA pair via adclib's OpenSSL bindings and write them to disk.

    Pure-Lua + adclib C: no shell-out, no openssl-on-PATH dependency
    at runtime. The certs/make_cert.{sh,bat} scripts stay around for
    operators who want to regenerate certs manually (e.g. after a
    hostname change or for cert rotation cron jobs).

    Public surface:
        ensure_cert(cert_path, key_path, ca_path) -> (true, generated)
                                                  -> (false, err)
        compute_keyprint_b32(cert_path)           -> "BASE32STRING"
                                                  -> nil, err

    The keyprint is the SHA-256 fingerprint of the DER-encoded cert,
    base32-encoded with no padding, ready to paste into an
    adcs://host:port/?kp=SHA256/<keyprint> URL.

]]--

local use = use

local io = use "io"
local os = use "os"
local string = use "string"
local table = use "table"
local tostring = use "tostring"

local io_open = io.open
local io_write = io.write

local adclib = use "adclib"
local basexx = use "basexx"
local util = use "util"

local adclib_random_bytes = adclib.random_bytes
local adclib_gen_self_signed_cert = adclib.gen_self_signed_cert
local adclib_cert_fingerprint_sha256 = adclib.cert_fingerprint_sha256

-- Late-bound: cfg / out are loaded as core modules in init.lua. We
-- belong to _core too so init.lua's init-loop invokes our init()
-- after cfg and out are up but BEFORE hub.init() runs (hub.init
-- binds listeners via wrapserver, which fails fast on missing
-- cert; cert generation MUST complete before that).
local cfg_get
local out_put
local out_error

-- Boot-time message helpers. The keyprint and the "generated cert"
-- notice MUST land on stdout (not just on log/event.log via
-- out.put) so operators can grab them from `docker logs` or the
-- terminal that started the hub. We mirror to out.put for the
-- on-disk forensic trail; out.put writes to event.log only when
-- cfg.log_events is true, otherwise it is a no-op.
local function _bootmsg( ... )
    io_write( "\n", ... )
    if out_put then out_put( ... ) end
end

local function _booterr( ... )
    io_write( "\n", ... )
    if out_error then out_error( ... ) end
end

-- Cert-validity in days. 10 years; matches certs/make_cert.sh's
-- pre-existing convention for self-signed deployments.
local CERT_DAYS = 3650

-- Length (in random bytes) of the CN. The script formats the bytes
-- as hex so 16 random bytes => 32 hex chars subject CN. Just enough
-- entropy that two fresh deployments do not share a fingerprint.
local CN_RAND_BYTES = 16

local function _file_exists( path )
    local f = io_open( path, "rb" )
    if f then f:close( ); return true end
    return false
end

local function _bin_to_hex( bin )
    local n = #bin
    local hex = {}
    for i = 1, n do
        hex[i] = string.format( "%02x", string.byte( bin, i ) )
    end
    return table.concat( hex )
end

-- Generate cert + key as PEM strings. Wrapper around the C function;
-- handles the (nil, err) failure shape and surfaces a single err
-- string to the caller.
local function _generate_pem( cn )
    local key_pem, cert_pem = adclib_gen_self_signed_cert( cn, CERT_DAYS )
    if not key_pem then
        return nil, nil, ( cert_pem or "gen_self_signed_cert failed" )
    end
    return key_pem, cert_pem
end

-- Atomic write: tmp + rename, mode 600 on the key (private),
-- world-readable for the cert (public). Pattern mirrors cfg_users
-- saveusers; reused here so a power-loss mid-cert-write cannot leave
-- a half-written keyfile.
local function _write_secret( path, content )
    local tmp = path .. ".tmp"
    local f, err = io_open( tmp, "wb" )
    if not f then return false, err end
    f:write( content )
    f:close( )
    util.chmod_secret( tmp )    -- chmod 600 (POSIX) before rename
    os.remove( path )           -- Windows fallback (POSIX rename overwrites)
    local ok, rerr = os.rename( tmp, path )
    if not ok then
        os.remove( tmp )
        return false, rerr or "rename failed"
    end
    return true
end

local function _write_public( path, content )
    local tmp = path .. ".tmp"
    local f, err = io_open( tmp, "wb" )
    if not f then return false, err end
    f:write( content )
    f:close( )
    os.remove( path )
    local ok, rerr = os.rename( tmp, path )
    if not ok then
        os.remove( tmp )
        return false, rerr or "rename failed"
    end
    return true
end

-- Generate cert + key only if neither already exists. Idempotent: a
-- second call after the cert is on disk is a no-op. Returns
-- (true, generated_bool) on success; (false, err) on failure.
--
-- A `ca_path` may be passed too (defaults to nil). If given, the
-- self-signed cert is also written there - server.lua's wrapserver
-- enforces existence of every file referenced in sslctx, including
-- ssl_params.cafile, but in self-signed mode the cert IS its own CA.
-- Writing the same bytes to both servercert.pem and cacert.pem
-- satisfies the existence check without introducing a separate
-- root-CA-and-leaf-cert split that the legacy make_cert.sh script
-- did purely as a stylistic choice.
local function ensure_cert( cert_path, key_path, ca_path )
    if _file_exists( cert_path ) and _file_exists( key_path )
       and ( not ca_path or _file_exists( ca_path ) ) then
        return true, false
    end

    -- Random hex CN. The bytes from adclib.random_bytes come from
    -- OpenSSL RAND_bytes which is seeded from /dev/urandom (or the
    -- equivalent OS source on Windows).
    local cn_bin, rerr = adclib_random_bytes( CN_RAND_BYTES )
    if not cn_bin then
        return false, "random_bytes for CN failed: " .. tostring( rerr )
    end
    local cn = _bin_to_hex( cn_bin )

    local key_pem, cert_pem, gen_err = _generate_pem( cn )
    if not key_pem then
        return false, gen_err
    end

    local ok, werr = _write_secret( key_path, key_pem )
    if not ok then
        return false, "write key: " .. tostring( werr )
    end
    ok, werr = _write_public( cert_path, cert_pem )
    if not ok then
        return false, "write cert: " .. tostring( werr )
    end
    if ca_path then
        ok, werr = _write_public( ca_path, cert_pem )
        if not ok then
            return false, "write ca: " .. tostring( werr )
        end
    end

    return true, true    -- generated=true so caller can log it
end

-- Compute SHA-256 keyprint of cert at `cert_path` and return as
-- base32 (no padding) - the form that goes into the adcs:// URL.
local function compute_keyprint_b32( cert_path )
    local f = io_open( cert_path, "rb" )
    if not f then
        return nil, "cert not found at " .. tostring( cert_path )
    end
    local pem = f:read "*a"
    f:close( )

    local raw, err = adclib_cert_fingerprint_sha256( pem )
    if not raw then
        return nil, err or "fingerprint failed"
    end

    -- basexx returns padded output; the kp= URL convention is
    -- unpadded base32, so we strip trailing '='.
    local b32 = basexx.to_base32( raw ):gsub( "=+$", "" )
    return b32
end

-- core-module init: called once from init.lua's import() loop after
-- cfg and out are loaded (and before hub.init() binds listeners).
-- If TLS is enabled and the configured cert is missing, generate
-- a fresh self-signed cert and key. Then log the keyprint regardless,
-- so operators can grab it from `docker logs` / hub stdout on every
-- boot.
local function init( )
    cfg_get = use( "cfg" ).get
    local out = use "out"
    out_put = out.put
    out_error = out.error

    if not cfg_get "use_ssl" then
        return
    end

    local ssl_params = cfg_get "ssl_params" or { }
    local cert_path = ssl_params.certificate or "certs/servercert.pem"
    local key_path  = ssl_params.key         or "certs/serverkey.pem"
    local ca_path   = ssl_params.cafile      or "certs/cacert.pem"

    local ok, generated = ensure_cert( cert_path, key_path, ca_path )
    if not ok then
        _booterr( "cert_bootstrap: ", tostring( generated ) )
        return
    end
    if generated then
        _bootmsg( "cert_bootstrap: generated self-signed P-256 cert at ", cert_path )
    end

    local kp, kperr = compute_keyprint_b32( cert_path )
    if kp then
        _bootmsg( "TLS keyprint (SHA256, base32): ", kp )
        _bootmsg( "share with users as: adcs://<your-host>:<ssl_port>/?kp=SHA256/", kp )
    else
        _booterr( "cert_bootstrap: keyprint failed: ", tostring( kperr ) )
    end
end

return {
    init                   = init,
    ensure_cert            = ensure_cert,
    compute_keyprint_b32   = compute_keyprint_b32,
}
