# Phase 2 — Quick wins + reproducible Windows build

> Working agreement: see [`CLAUDE.md`](../../CLAUDE.md) §1.
> Roadmap: see [`CLAUDE.md`](../../CLAUDE.md) §5.

**Status:** complete
**Started:** 2026-05-02
**Closed:** 2026-05-02
**Goal:** Pick off small low-risk issues that improve consistency without
changing behaviour, and make the Windows build reproducible. Full Windows
build modernisation (CMake) is **its own phase** — see Phase 5.

---

## 1. Activities

Six pull requests landed during Phase 2. Each one closed a single GitHub
issue, was reviewed in isolation, and was smoketested on at least Linux
(some on both platforms).

| PR  | Issue | One-line summary                                                            |
|-----|-------|-----------------------------------------------------------------------------|
| #7  | #1    | Add `.gitattributes`, renormalize 252 tracked files to match               |
| #8  | #5    | Rename `UID` → `RAND_ID` in `examples/certs/make_cert.sh` (bash collision) |
| #9  | #2    | Drop deprecated `register` keyword from `adclib/tiger.cpp` (12 warnings)   |
| #11 | #10   | Replace `lua_open()` with `luaL_newstate()` in `hub/hub.c`                 |
| #13 | #4    | Route `+!#` server commands from PM-to-hubbot through command pipeline     |
| #17 | #14   | Make Windows build reproducible (ENV vars, sanity checks, no pauses)       |

### 1.1 Repo hygiene (PR #7)

`.gitattributes` was missing. Windows checkouts (default
`core.autocrlf=true`) shipped CRLF line endings on shell scripts, breaking
the WSL build immediately with a `bash: line 1: ./compile: cannot execute`
error caused by `\r` in the shebang.

The PR pinned the policy explicitly: `*.sh`, `*.lua`, `*.c`, `*.cpp`,
`*.h`, `Makefile`, `compile`, `cleanall`, `*.tbl`, `*.lang`, `*.md`, `*.txt`
→ LF; `*.bat`, `*.cmd` → CRLF; common binary types → `binary`. The 252
already-tracked files were renormalized in a separate commit so the
mass change can be skipped via `git blame --ignore-rev` if it ever clutters
blame output.

### 1.2 Cert-generation portability (PR #8)

`examples/certs/make_cert.sh` used `UID` as a variable for the random
Common Name. `UID` is a read-only built-in in **bash**, so anyone running
the script via `bash make_cert.sh` (rather than `./make_cert.sh` which
goes through `dash` on Debian/Ubuntu) silently got a degraded CN of `1000`
(the user's UID) instead of a random hex string. Fix: rename to `RAND_ID`.

### 1.3 Compiler warnings cleanup (PR #9)

`adclib/tiger.cpp` declared 13 variables with `register` storage class —
removed in C++17, and emitted 12 `-Wregister` warnings on every adclib
build with gcc 13+. Two-line fix; generated machine code is byte-identical
because modern compilers ignore the hint.

### 1.4 Lua 5.1 → 5.2 forward-compat preparation (PR #11)

`hub/hub.c:128` initialised the Lua state via the legacy `lua_open()`
spelling, deprecated in Lua 5.1 and removed in Lua 5.2. The replacement
`luaL_newstate()` is preprocessor-equivalent on our current Lua 5.1
runtime (`#define lua_open() luaL_newstate()`) so the change is risk-free
in the current configuration; it removes one source of conditional fixes
from the upcoming Phase 3 migration.

### 1.5 Hub-bot command routing (PR #13)

AirDC++ and other DC clients route a leading `+`, `!` or `#` in the chat
input as a *server command* via private message to the hub bot, not as a
main-chat broadcast. The hub previously replied to every EMSG-to-hubbot
with the i18n `"I am the Hubbot, do you really want to talk to me?"`
deflection, so server commands silently never reached `cmd_*` scripts.

Fix: restore the old PM-to-broadcast bridge that had been commented out
(replaced with the deflection-only path in some prior change), but gate it
on a `^[+!#]` prefix match. Plain PMs to the bot still get the polite
deflection, preserving the original "don't trigger handlers by chatting at
the bot" intent.

This was the only PR in Phase 2 that touched `core/hub.lua`. Per the
working agreement (§1.1, security-sensitive code) it was reviewed in
isolation, smoketested with three explicit cases:
- `+help` in main chat → command pipeline runs (was: deflection)
- `+myip` in main chat → command pipeline runs (was: deflection)
- Plain "Hi bot" PM → deflection still applies (regression check)

### 1.6 Reproducible Windows build (PR #17)

`compile_with_mingw.bat` had three reproducibility blockers:
- Hardcoded `C:\MinGW` and `C:\OpenSSL` with no override
- Mid-build cryptic errors when the toolchain wasn't where it expected it
- Two `@pause` calls blocking unattended use

Fix: read locations from `LUADCH_MINGW_DIR` / `LUADCH_OPENSSL_DIR` env
vars (defaulting to legacy paths), add up-front sanity checks that exit
with actionable messages naming the missing file and the env var that
overrides it, and remove the pauses. Full setup walkthrough captured in
new [`docs/BUILDING.md`](../BUILDING.md).

The `*.c.not` rename trick during the LuaSocket build is intentionally
left untouched — replacing it requires the build-system rewrite tracked
in Phase 5 (issue #15).

---

## 2. Findings

### Filed and closed in Phase 2

| #  | Title                                                            | Closed by |
|----|------------------------------------------------------------------|-----------|
| #1 | Missing `.gitattributes` causes Linux build to fail on Windows checkout | PR #7 |
| #2 | C++17 `register` storage-class warnings in `adclib/tiger.cpp`    | PR #9     |
| #4 | `+help` / `+myip` return bot deflection for `dummy` account      | PR #13    |
| #5 | `make_cert.sh` uses `UID` — collides with bash readonly builtin  | PR #8     |
| #10| Replace deprecated `lua_open()` with `luaL_newstate()`           | PR #11    |
| #14| Make Windows build reproducible: ENV variables, sanity checks    | PR #17    |

### Filed during Phase 2, deferred to later phases

| #   | Title                                                                | Phase |
|-----|----------------------------------------------------------------------|-------|
| #12 | Anchor runtime paths to binary/script location instead of CWD       | 6     |
| #15 | Migrate to CMake for unified cross-platform build                   | 5     |
| #16 | `cmd_hubinfo.lua` uses `wmic` which is removed in Windows 11 24H2+ | 6     |

### Decided "no follow-up" in Phase 2

- 2-arg `user:reply(msg, bot)` vs. 3-arg `user:reply(msg, bot, bot)`
  inconsistency across `cmd_*` scripts (cmd_myip et al. render in
  mainchat tab; cmd_help in PM tab). Verified that no message is leaked
  to other users either way (`core/hub.lua:1576`); BMSG-to-one-socket
  only goes to the addressed user. Verdict: by-design UI-placement
  difference, not a security or behaviour bug. Not even worth tracking
  as an issue.

---

## 3. Build statistics

Compiler-warning evolution under default flags:

| Configuration                  | Errors | Warnings | Breakdown                       |
|--------------------------------|--------|----------|---------------------------------|
| Phase 1 baseline (Linux gcc 13)| 0      | 17       | 12× register, 5× OpenSSL 3.0 dep |
| End of Phase 2 (Linux gcc 13)  | 0      | 5        | 0× register, 5× OpenSSL 3.0 dep  |
| End of Phase 2 (Windows gcc 16)| 0      | 7        | gcc-16-stricter style warnings   |

The 5 OpenSSL deprecation warnings are tracked in issue #3 (Phase 4
LuaSec bump). The 7 Windows warnings are gcc-16 stylistic suggestions
not present under gcc 13 — discoveries, not regressions.

---

## 4. Smoketest summary

| Test                                                                 | Linux | Windows |
|----------------------------------------------------------------------|-------|---------|
| Clean build from scratch                                             | ✅    | ✅      |
| Hub binary launches, all 24 init.lua steps complete, banner prints  | ✅    | ✅      |
| Plain ADC port 5000 binds                                            | ✅    | ✅      |
| TLS port 5001 binds (after `make_cert.{sh,bat}`)                     | ✅    | ✅      |
| AirDC++ connect over `adc://`                                        | ✅    | ✅ (TLS) |
| `+help` and `+myip` reach command pipeline (post PR #13)             | ✅    | ✅      |
| Plain PM to hubbot still receives deflection                         | ✅    | (n/a)   |

Footnote: on Windows 11 24H2+, the hub stderr also shows three
`Der Befehl "wmic" ist…` lines from `cmd_hubinfo.lua` startup. Tracked in
issue #16. Non-blocking — the hub still binds and accepts connections.

---

## 5. Review gate

Per CLAUDE.md §1.4, four categories were walked through before declaring
Phase 2 complete.

### 5.1 Security

**Single security-sensitive change in Phase 2: PR #13** (hub-bot EMSG
handler in `core/hub.lua`). Mitigations:

- The new behaviour is gated on `text:match("^[+!#]")` — only messages
  with a known command prefix are routed; plain text is deflected as before.
- The added work per EMSG is one `string.match`. Negligible CPU.
- Variables used (`escapefrom`, `scripts_firelistener`) are file-scope
  locals already populated by the time the closure can fire (line 248
  and 943 of `core/hub.lua`).
- Regression-tested with three explicit cases (see §1.5).

PR #8 was security-adjacent: previously, certs generated via `bash
make_cert.sh` had a predictable Common Name (`1000`) that revealed the
running user's UID. Now they are properly random in every shell.

PRs #7 / #9 / #11 / #17 either touched only build infrastructure or
were preprocessor-equivalent — no security surface change.

**Verdict:** ✅ no regression; one small security-positive change.

### 5.2 Consistency

- `.gitattributes` (PR #7) is the strongest consistency win of the phase:
  every contributor on every platform now gets the same line endings.
- The Windows build now follows the same env-var-driven configuration
  pattern as any modern build script — no more "edit the .bat to your
  paths" tribal knowledge.
- The `cmd_hubinfo.lua` `wmic` issue (#16) and the `user:reply` 2-arg /
  3-arg variation are pre-existing inconsistencies that we are aware of
  and have classified explicitly (deferred / by-design).
- We did **not** introduce any new divergent code paths.

**Verdict:** ✅ consistency improved; no new fragmentation.

### 5.3 Code quality

- Removed 12 vestigial `register` keywords (PR #9).
- Removed 1 commented-out 5-line block in `core/hub.lua` that had been
  preserved as historical fossil (PR #13).
- Removed 2 vestigial `@pause` calls and the obsolete instructional
  header from `compile_with_mingw.bat` (PR #17).
- Total source delta excluding renormalization: about +30 / −25 lines of
  meaningful code; all the rest is documentation gain (`docs/BUILDING.md`,
  this document) and policy capture (`.gitattributes`).
- `core/cfg.lua` (3688 lines) and `core/hub.lua` (2239 + 6 = 2245 lines
  after the bridge fix) are still the structural elephants — Phase 6
  refactor target.

**Verdict:** ✅ net-positive; no new bloat or duplication.

### 5.4 Build and smoketest

Covered in §3 and §4 above. **Both platforms green from clean checkout.**

---

## 6. Phase 3 entry criteria

Phase 3 is the Lua 5.1 → 5.4 migration. Recommended preconditions before
starting:

1. Master is at PR #17 (Phase 2 final), no uncommitted work, no
   long-running branches.
2. The bundled Lua 5.1.5 source under `lua/src/` is the migration target;
   replace with Lua 5.4.x source.
3. Read the Lua 5.1 → 5.4 incompatibility lists in upstream Lua docs
   before touching code; they're short but exhaustive.
4. Plan the sequence (suggested):
   - Bump Lua source first, build, see what breaks.
   - Fix C-side compile breakage in `hub/hub.c`, `adclib/`, `slnunicode/`
     (lua_pushinteger semantics, lua_objlen → lua_rawlen, etc.).
   - Fix Lua-side breakage in `core/init.lua`, `core/scripts.lua`
     (`setfenv`/`getfenv` → `_ENV`; `loadstring` → `load`;
     `unpack` → `table.unpack`).
   - Re-verify all 70+ scripts in `scripts/` load and run.
5. Do **not** combine Phase 3 with dependency bumps — those are Phase 4.
   Keep the Lua-runtime change isolated so any regression has a single
   root cause to investigate.

---

## 7. Phase 2 review-gate checklist

- [x] All planned items merged (#7, #8, #9, #11, #13, #17)
- [x] Linux build green from clean checkout (`./compile`, exit 0, no errors)
- [x] Windows build green from clean checkout (`compile_with_mingw.bat`, exit 0, ~25s)
- [x] Smoketest passes on both platforms (see §4)
- [x] Security review of `core/hub.lua` change (§5.1)
- [x] Consistency review (§5.2)
- [x] Code-quality review (§5.3)
- [x] Build statistics captured (§3)
- [x] All findings logged: 6 closed issues + 3 deferred + 1 by-design verdict
- [x] Phase 3 entry criteria documented (§6)
- [x] No source-code modifications outside the merged PRs

Phase 2 is closed. Phase 3 (Lua 5.1 → 5.4 migration) may begin.
