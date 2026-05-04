# Phase 7 - Security audit & hardening

> Working agreement: see [`CLAUDE.md`](../../CLAUDE.md) §1.
> Roadmap: see [`CLAUDE.md`](../../CLAUDE.md) §5.

**Status:** complete
**Started:** 2026-05-04
**Closed:** 2026-05-04
**Goal:** Systematic security audit of the modernised Phase-6 codebase
followed by targeted fixes. The audit (7a) produced 24 findings;
sub-phases 7b-7h fixed 22 of them, deferred one (F-AUTH-1 transparent
KDF migration) as protocol-immanent with documented mitigations, and
kept one (F-DEP-2 LuaSec OpenSSL-3 deprecated APIs) as
`upstream-blocked`. New top-level docs: `docs/SECURITY.md`.

---

## 1. PRs in order

| PR | Phase | What |
|---|---|---|
| #59 | 7a | Read-only audit; `docs/phases/PHASE_7_FINDINGS.md`; 8 issues filed (#51-58) |
| #60 | 7b | F-AUTH-2: CSPRNG salts via OpenSSL `RAND_bytes`; drop `math.randomseed(os.time())`; new `adclib.random_bytes` (closes #53) |
| #61 | 7b | F-C-1 + F-C-3: bound salt VLAs (`MAX_SALT_BYTES = 64`) + `luaL_checklstring` in adclib hash_pas / hash_pas_oldschool / hash_pid (closes #54) |
| #62 | 7b | F-SEC-1: chmod 600 on user.tbl + cert keys; `make_cert.sh` 0600s the generated keys; Windows icacls recipe in BUILDING.md |
| #63 | 7b | F-DEP-1: bundled Lua 5.4.7 -> 5.4.8 (drop-in upstream sync) |
| #64 | 7c | F-NET-1, F-NET-2, F-AUTH-3, F-RL-1, F-RL-2: new `core/ratelimit.lua` token-bucket module + per-IP / per-user / TLS-handshake hooks (closes #56) |
| #65 | 7d | F-PRS-1..5: ADC parser validators (`%c` rejection), reentrant `parse()` (parse-locals instead of module-globals), 64 KiB command size cap, re-enabled UTF-8 entry check (closes #57) |
| #66 | 7e | F-FIO-1: `loadtable()` runs chunks with empty `_ENV`; eliminates RCE on tampered `.tbl` files (closes #51) |
| #67 | 7f | F-AUTH-1: AES-256-GCM at-rest encryption of `cfg/user.tbl` via new `core/cfg_secret.lua`; auto-managed `cfg/master.key` with chmod 600 enforcement (closes #52) |
| #68 | 7g | F-C-2, F-C-4, F-C-5, F-DEP-3, F-DEP-4, F-PRS-6, F-SAND-1: hygiene fixes + new `docs/SECURITY.md` (closes #58) |
| #69 | 7h | F-AUTH-1 follow-up: configurable `master_key_path` cfg key for backup separation; key can live outside the install dir |

---

## 2. Recurring techniques

### Defence-in-depth around protocol-mandated cleartext

ADC `BASE` HPAS forces the hub to hold a password-equivalent secret
in process memory at login time (the salted Tiger challenge needs to
be recomputed with a fresh per-login salt). A pure server-side KDF
migration (Argon2id, bcrypt, scrypt) is therefore impossible without
a protocol extension. Phase 7 took the only path that works
short-term: layer defences around the unavoidable cleartext.

- **At-rest** (PR #67): AES-256-GCM with a host-bound master key.
  Cleartext is materialised in RAM at decryption time, never on disk.
- **Master-key separation** (PR #69): `master_key_path` cfg key lets
  the operator put the key outside `cfg/` so a routine `cfg/` backup
  carries only the encrypted blob, not its decryption key.
- **chmod 600 enforcement** (PR #62, PR #67): hub refuses to start
  if `master.key` mode != 0600 on POSIX, modeled on OpenSSH's
  `~/.ssh/id_rsa` strict-mode check.
- **CSPRNG salt** (PR #60): the per-login salt is now from OpenSSL
  `RAND_bytes`, not Lua's `math.random` reseeded with `os.time()`,
  so an attacker who guesses the admin's password-generation moment
  cannot enumerate.

The protocol-mandated in-RAM exposure is honestly documented in
`docs/SECURITY.md` §3 and tracked as the modeled-equivalent of
Firefox primary password / Telegram local DB / Apple Keychain
in unlocked state.

### Sandbox-via-empty-`_ENV`

PR #66 (F-FIO-1) eliminated the entire universal-loadfile RCE
class with a one-line change: `loadfile(path, "t", { })` instead of
`loadfile(path)`. Empty `_ENV` denies the chunk access to `os`, `io`,
`debug`, `package`, `require`, `dofile`, etc. - so a tampered `.tbl`
file cannot reach the host. The format on disk stays the same Lua
`return { ... }` shape, which means **zero migration** for the 50+
call sites and existing deployments. The original issue floated a
hand-rolled non-executable parser (~300 LoC) or JSON via dkjson (new
dep + data migration); the empty-env sandbox does the same job for
the actual threat (RCE) at the cost of a 1-line change.

### Token-bucket per (bucket_id, kind)

The PR-#64 rate-limit module uses one token-bucket dictionary keyed
by `bucket_id` (e.g. `"ip:1.2.3.4"`, `"user:CID"`) and `kind` (e.g.
`"conn"`, `"msg"`, `"search"`, `"authfail"`). One module covers six
distinct rate-limit hooks (per-IP connection cap + rate, TLS
handshake deadline, per-IP failed-auth, per-user chat, per-user
search) without per-hook code duplication. Cleanup is a single tick
walk shared by all bucket families.

### chmod-or-die at boot

The hub refuses to start if a secret file's POSIX mode is wrong.
Same pattern OpenSSH applies to `~/.ssh/id_rsa`. Forces operators
to set permissions correctly at install time rather than relying on
"hopefully nobody backed up world-readable files".

### bind_late() pattern, again

Phase 6 introduced this pattern for the cfg / hub decompositions
(see [`PHASE_6.md`](PHASE_6.md) §2). Phase 7 reused it twice: once
for the `core/ratelimit.lua` cfg cache, once for `core/cfg_secret.lua`
where `cfg_get("master_key_path")` is needed during init but cfg
itself isn't fully populated yet. PR #69 specifically moved
`cfg_secret.init()` out of init.lua's `_core` init phase and into
the bottom of `cfg.init()` for exactly this reason.

### Smoke harness as security-regression net

The Phase-6 smoke harness gained three Phase-7-specific tests:

```
[smoke] PASS  CSPRNG salts are unique across connections     (#60)
[smoke] PASS  per-IP connection cap refuses overflow          (#64)
[smoke] PASS  user.tbl encrypted at rest                      (#67)
```

10 protocol-level tests now run on every push and PR via
`.github/workflows/smoke.yml`. A regression in any of the security
mechanisms - PRNG seeded back to `os.time()`, accept loop bypassing
the per-IP cap, encryption silently disabled - would fail in CI
before merge.

---

## 3. Module-state shapes after Phase 7

```
core/
  init.lua                214  (bootstrap, sandbox env)
  const.lua                22  (PROGRAM_NAME, VERSION, paths)
  mem.lua                  32  (GC trigger)
  signal.lua               41  (timers, start time)
  out.lua                  99  (logging, listener registry)
  types.lua               159  (ADC type validators)
  hci.lua                   9  (hubruntime persistence helper)
  cfg_secret.lua          257  (Phase 7f: master.key, AES-GCM seal/open)
  ratelimit.lua           296  (Phase 7c: token-bucket hooks)
  scripts.lua             264  (plugin loader, sandbox, hook registry)
  doc.lua                 308  (auto-doc, currently unused)
  cfg_users.lua           196  (user.tbl I/O, Phase 7f encryption hooks)
  cfg_lang.lua             68  (language file loader)
  hub_bot_object.lua      318  (createbot factory)
  hub_user_object.lua     480  (createuser factory)
  hub_dispatch.lua        503  (state-machine handler tables, rate-limit hooks)
  cfg.lua                 674  (orchestrator, drives cfg_secret.init)
  util.lua                789  (file I/O, encoding, UTF-8, table helpers,
                                 chmod_secret, arraytostring, loadtable_string)
  adc.lua                 954  (ADC protocol parse/format,
                                 Phase 7d parser hardening)
  server.lua             1019  (network select loop, SSL, rate-limit hooks)
  hub.lua                1497  (orchestrator, under ceiling per Phase 6)
  cfg_defaults.lua       3164  (data table, ceiling-exempt by CLAUDE.md §5)
hub/
  hub.c                   292  (Phase 7g: atexit return-value check)
adclib/
  adclib.cpp              ~530 (+random_bytes, aes_gcm_seal, aes_gcm_open;
                                 luaL_checklstring everywhere)
  tiger.cpp                    (Phase 7g: explicit parens, aligned ull[],
                                 endian-safe length finalize)
tests/
  smoke/run.py            629  (10 protocol-level tests)
docs/
  SECURITY.md             NEW  (threat model, plugin contract, F-AUTH-1
                                 disclosure, file perms, rate-limit map,
                                 backup separation, CVE process,
                                 reporting channel, audit history)
  phases/PHASE_7.md       NEW  (this file)
  phases/PHASE_7_FINDINGS.md   (audit findings doc, master traceability)
```

All Phase-6 ceilings still hold: every code module under 1500 lines
except `cfg_defaults.lua` (flat data table, exempt). The two new
modules sit comfortably under the ceiling at 257 and 296 lines.

---

## 4. Review-gate findings

### 4.1 Smoke-test suite green in CI on Linux and Windows

10/10 PASS verified across every Phase-7 PR on both `smoke-linux`
(ubuntu-latest) and `smoke-windows` (windows-latest with msys2
UCRT64). Three new Phase-7-specific tests added to the existing
seven from Phase 6.

### 4.2 Module line ceiling (1500)

Unchanged from Phase 6: every code module under 1500 except
`cfg_defaults.lua` (3164, exempt as a flat data table per CLAUDE.md
§5 and its file header - grew slightly with the rate-limit and
master_key_path keys).

### 4.3 Function line ceiling (100)

No new functions over 100 lines introduced in Phase 7. The five
pre-existing exceptions documented in
[`PHASE_6.md`](PHASE_6.md) §4.3 are unchanged.

### 4.4 Severity rollup

| Severity | Found | Fixed | Wontfix | Upstream-blocked |
|---|---|---|---|---|
| critical | 1 | 1 | 0 | 0 |
| high | 3 | 2 | 1 (F-AUTH-1 *transparent KDF migration*; mitigated via at-rest + chmod) | 0 |
| medium | 9 | 8 | 0 | 1 (F-DEP-2 LuaSec) |
| low | 7 | 7 | 0 | 0 |
| info | 4 | 4 | 0 | 0 |

24 findings filed; 22 closed directly; F-AUTH-1 closed-as-mitigated
(documented in `docs/SECURITY.md` §3 with the explicit trade-off);
F-DEP-2 stays classified as `upstream-blocked` per Phase 4.

### 4.5 No critical or high-severity finding remains unaddressed

Per the Phase-7 review-gate exit criterion in
[`PHASE_7_FINDINGS.md`](PHASE_7_FINDINGS.md) §5.

### 4.6 Manual smoke

Exercised live: hub start, dummy/test login on plain (5000) and
TLS (5001), `+hubinfo` renders correctly, `+shutdown` countdown
blocks user typing (Phase-2 fix still works), keyprint
auto-generated correctly on TLS startup, `master.key` regenerated
correctly at the configured path when `master_key_path` set,
backwards-compat plaintext-user.tbl correctly migrates to encrypted
on first save.

---

## 5. Items not closed in Phase 7

### F-AUTH-1 (high) - protocol-immanent residual risk

Standard ADC `BASE` HPAS requires a password-equivalent secret in
process memory at login time. Pure server-side Argon2id / bcrypt /
scrypt migration is impossible without a protocol extension. The
entire ADC ecosystem (ADCH++, uHub, PtokaX, …) shares this property.

Phase 7f mitigated the at-rest exposure with AES-256-GCM
encryption + master-key chmod 600 + (PR #69) configurable key path
for backup separation. Phase 7g documented the residual in-RAM
exposure honestly in `docs/SECURITY.md` §3.

A long-track ADC protocol extension proposal (`HSPW` or similar:
server stores `Argon2id(password, salt)`, login becomes
`Tiger(H_outer || login_salt)`) is filed as Phase-8+ candidate in
[#48](https://github.com/Aybook/luadch/issues/48). Adoption would
require DC++ / AirDC++ upstream cooperation.

### F-DEP-2 (medium, upstream-blocked) - LuaSec OpenSSL-3 deprecated APIs

LuaSec 1.3.2 calls `SSL_library_init`, `OpenSSL_add_all_algorithms`,
`PEM_read_bio_DHparams`, `SSL_CTX_set_tmp_dh_callback` - all
`OPENSSL_NO_DEPRECATED_3_0`-tagged in OpenSSL 3.x. Functionally OK
because OpenSSL 3 auto-inits and the deprecated DH path still works.
Issue [#3](https://github.com/Aybook/luadch/issues/3) tracks the
upstream-blocked status. Re-evaluate when upstream cuts LuaSec 1.4.x
or assess `lua-openssl` as a replacement (network-stack-renewal
scope, deferred).

### Phase 8+ candidates

Tracked in [#48](https://github.com/Aybook/luadch/issues/48):

- OS-bound master-key wrapping (TPM via `tpm2-tss`, DPAPI machine-scope,
  libsecret, macOS Keychain)
- HSPW / SCRAM-Tiger ADC protocol extension proposal
- `wrapconnection` / `parse` / `wrapserver` 100-line refactors
  (pre-existing, untouched in Phase 6 + 7)
- Multi-hash schema for the user database
- `getbot` enumeration, `removeListener` counterpart, usr_nick_length
  codepoint fix, usr_nick_prefix `onInf`, i18n gaps

---

## 6. What is next

Master is at the merged Phase-7 state. **Phase 7 is content-complete
and the modernisation programme is now security-audited.**

The project is on Lua 5.4.8, on a current build system, with clear
module boundaries, a smoke-test floor catching protocol-level
regressions, defence-in-depth around the protocol-mandated cleartext
(at-rest encryption, separable master key, chmod 600 enforcement,
CSPRNG salts), DoS hardening (per-IP / per-user rate limits, TLS
handshake deadline), parser hardening (control-byte rejection,
reentrant `parse()`, message-size cap), and an honest threat-model
disclosure in `docs/SECURITY.md`.

Phase 8+ is feature-territory rather than modernisation. Reserved
items live in [#48](https://github.com/Aybook/luadch/issues/48) per
the modernisation roadmap in [`CLAUDE.md`](../../CLAUDE.md) §5
"Phase 8+ - Future features".
