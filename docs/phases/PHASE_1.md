# Phase 1 — Foundation

> Working agreement: see [`CLAUDE.md`](../../CLAUDE.md) §1.
> Roadmap: see [`CLAUDE.md`](../../CLAUDE.md) §5.

**Status:** complete
**Started:** 2026-05-01
**Closed:** 2026-05-02
**Goal:** Reproducible build on Linux and Windows, smoke test passes, baseline
documented. **No source modification in this phase.**

---

## 1. Activities

### 1.1 Linux build via WSL2

**Environment**
- Host: Windows 11
- WSL2 distribution: Ubuntu 24.04
- Toolchain: `gcc` 13.3.0, `make`, `rsync` (preinstalled)
- System OpenSSL: 3.0.x (Ubuntu 24.04 default)

**First attempt — failed.** Running `./compile` against the Windows checkout
mounted at `/mnt/<drive>/Projekte/luadch` failed with:

```
bash: line 1: ./compile: cannot execute: required file not found
```

Root cause: shell scripts had CRLF line endings because Git on Windows applied
its default `core.autocrlf=true` during clone. The shebang `#!/bin/sh\r` is
not a valid interpreter path on Linux. Filed as **issue #1**.

**Workaround used.** Cloned the repo a second time inside the WSL filesystem
(`~/luadch`), where Linux Git checks out with native LF endings. Build then
succeeded without modification.

This is a **Phase 1 finding, not a Phase 1 fix.** The repo will get a
`.gitattributes` file in Phase 2.

**Build output.** `./compile` produced `build_gcc/luadch/` with everything
listed in §3 below. 0 errors, 17 compiler warnings (categorized in §2).

### 1.2 Plain ADC smoketest (port 5000)

Hub launched from `build_gcc/luadch/`. Boot trace:

```
init.lua: import libs
init.lua: loaded 'adclib'
init.lua: loaded 'unicode'
init.lua: loaded 'socket'
init.lua: import optional libs
init.lua: loaded 'ssl'
init.lua: loaded 'basexx'
init.lua: import core
init.lua: loaded 'const' / 'mem' / 'signal' / 'doc' / 'util' / 'types'
init.lua: loaded 'cfg' / 'out' / 'server' / 'adc' / 'scripts' / 'hub'
init.lua: init core modules
init.lua: initialized 'util' / 'cfg'
```

Listener: `LISTEN 0  32  0.0.0.0:5000` ✓

AirDC++ login as `dummy` / `test` to `adc://127.0.0.1:5000` succeeded.
Main chat showed the expected `[BOT]HubSecurity` warning about the active
default account.

`+help` and `+myip` did **not** behave as expected — the bot returned
"I am the Hubbot, do you really want to talk to me?" instead of the help
list / IP. Filed as **issue #4** for triage in Phase 2. This is not a
Phase 1 blocker — the hub itself accepted the connection, processed input,
and responded. Command-routing detail is a separate question.

### 1.3 TLS smoketest (port 5001)

**Cert generation.** Ran `examples/certs/make_cert.sh` (copied to
`build_gcc/luadch/certs/` by the build) inside WSL. The script produced the
expected files:

```
cacert.pem      cakey.pem
servercert.pem  serverkey.pem
```

Subject CN of the CA cert is a 32-hex-char random ID when the script is
invoked via its shebang (`./make_cert.sh` → `/bin/sh` → `dash` on Ubuntu).
When invoked as `bash make_cert.sh`, the assignment to `UID` fails (bash
treats `UID` as a read-only builtin) and the CN ends up being the user's
numeric UID (e.g. `1000`). Filed as **issue #5**.

**Hub start with TLS.** The hub bound both ports cleanly:

```
LISTEN 0      32            0.0.0.0:5000      0.0.0.0:*
LISTEN 0      32            0.0.0.0:5001      0.0.0.0:*
```

**AirDC++ TLS connect** to `adcs://<wsl-ip>:5001` succeeded. The
HubSecurity bot reported the negotiated session:

```
TLS Mode:    TLSv1.3
TLS Cipher:  TLS_AES_256_GCM_SHA384
Client SSL:  yes
```

This is current best-practice cipher selection — confirms that LuaSec 1.3.2
plus the Ubuntu 24.04 system OpenSSL produce a modern, secure TLS session
without any explicit configuration in luadch's defaults.

**Note on connectivity.** Connecting from AirDC++ on Windows to the hub
running in WSL2 required the WSL guest IP (`172.18.x.y`), not
`127.0.0.1`. This indicates WSL2 is in **NAT mode** rather than the newer
Mirrored mode. This is an environmental detail of the test setup, not a
luadch issue.

### 1.4 Windows build

Out of scope for Phase 1 by agreement (see CLAUDE.md §5 Phase 1). The Windows
build will be modernized in Phase 2; the spec for what it must produce is
captured in §3 of this document.

---

## 2. Findings

| #  | Finding                                                          | Issue | Phase |
|----|------------------------------------------------------------------|-------|-------|
| F1 | Repo lacks `.gitattributes`; Windows checkout breaks Linux build | [#1](https://github.com/Aybook/luadch/issues/1) | 2 |
| F2 | C++17 `register` warnings in `adclib/tiger.cpp` (12×)            | [#2](https://github.com/Aybook/luadch/issues/2) | 2 |
| F3 | OpenSSL 3.0 deprecation warnings in LuaSec 1.3.2 (5 APIs)        | [#3](https://github.com/Aybook/luadch/issues/3) | 4 |
| F4 | `+help` / `+myip` return bot deflection for `dummy` account      | [#4](https://github.com/Aybook/luadch/issues/4) | 2 |
| F5 | `make_cert.sh` uses `UID` — collides with bash readonly builtin  | [#5](https://github.com/Aybook/luadch/issues/5) | 2 |

**Positive findings (no action needed):**

- TLS stack (LuaSec 1.3.2 + system OpenSSL 3.0.x) negotiates **TLSv1.3 with
  `TLS_AES_256_GCM_SHA384`** out of the box. No fallback to legacy ciphers
  observed. Default TLS posture is good.
- Boot is silent and fast — no script load failures, no errors during
  `init.lua` execution, no missing modules.
- The hub correctly warned about the active default `dummy` account on
  first login (HubSecurity bot doing its job).

Cosmetic non-issues (not filed):
- `ar: 'u' modifier ignored since 'D' is the default` — Ubuntu binutils notice; safe to ignore.

---

## 3. Build-output spec

This is the **acceptance contract** for Phase 2 Windows-build modernization
and any future build-system work: any new build must produce the same
artifacts in the same layout (paths relative to the build install dir).

### Top-level files

| File          | Type                              | Source        |
|---------------|-----------------------------------|---------------|
| `luadch`      | ELF / PE executable, dyn-linked   | `hub/hub.c`   |
| `liblua.so`   | Lua interpreter shared library    | `lua/src/`    |

### Native plugins

| Path                            | Source           |
|---------------------------------|------------------|
| `lib/adclib/adclib.so`          | `adclib/`        |
| `lib/unicode/unicode.so`        | `slnunicode/`    |
| `lib/luasocket/socket/socket.so`| `luasocket/src/` |
| `lib/luasocket/mime/mime.so`    | `luasocket/src/` |
| `lib/luasec/ssl/ssl.so`         | `luasec/src/`    |

### Lua libraries

| Path                            | Source              |
|---------------------------------|---------------------|
| `lib/luasocket/lua/*.lua`       | `luasocket/src/*.lua` (socket.lua, mime.lua, ltn12.lua, http.lua, headers.lua, smtp.lua, tp.lua, url.lua, mbox.lua, ftp.lua) |
| `lib/luasec/lua/*.lua`          | `luasec/src/` (https.lua, options.lua, ssl.lua) |
| `lib/basexx/basexx.lua`         | `basexx/`           |

### Runtime directories (copied from sources)

| Path        | Source                |
|-------------|-----------------------|
| `core/`     | `core/`               |
| `scripts/`  | `scripts/`            |
| `cfg/`      | `examples/cfg/`       |
| `certs/`    | `examples/certs/`     |
| `lang/`     | `examples/lang/`      |
| `docs/`     | `docs/`               |
| `log/`      | (created empty)       |

### Windows-specific differences

The Windows build (`compile_with_mingw.bat`) produces:
- `Luadch.exe` instead of `luadch`
- `lua.dll` instead of `liblua.so`
- `lib/.../*.dll` instead of `*.so`
- Bundled `libssl-3-x64.dll` and `libcrypto-3-x64.dll` at install root
- A windres-compiled icon resource (`res/res.rc` → `res/icon.o` linked into the exe)

Symbol export and link flags must match what the Lua runtime expects on
each platform. The current Windows .bat exports all symbols
(`-Wl,--export-all-symbols`) and produces `libluasocket.a` as an import
library — to be evaluated for necessity in Phase 2.

---

## 4. Build statistics (reference)

```
errors:    0
warnings: 17
  - 12× C++17 register-keyword (adclib/tiger.cpp)        → issue #2
  -  5× OpenSSL 3.0 deprecations (luasec)                → issue #3
```

## 5. Smoketest summary

| Test                                  | Result | Note                                        |
|---------------------------------------|--------|---------------------------------------------|
| Hub binary launches                   | ✅     | All 14 core modules + 5 native plugins load |
| Port 5000 (plain ADC) bound           | ✅     | `LISTEN 0.0.0.0:5000`                       |
| Port 5001 (TLS adcs) bound            | ✅     | After `make_cert.sh`                        |
| AirDC++ plain login (`dummy/test`)    | ✅     | HubSecurity warns about default account     |
| AirDC++ TLS login (`dummy/test`)      | ✅     | TLSv1.3 + `TLS_AES_256_GCM_SHA384`          |
| `+help` / `+myip` for dummy           | ❌     | Bot deflects — see issue #4                 |

---

## 6. Proposed Phase 2 entry criteria

Phase 2 (per CLAUDE.md §5) is **Quick wins & Windows build modernization**.
Recommended ordering, smallest blast-radius first:

1. **Issue #1** (`.gitattributes`) — must come first; unblocks every future
   cross-platform contributor and is required before the Windows-build work
   in step 4 below.
2. **Issue #5** (`make_cert.sh` UID variable) — one-line fix, low risk.
3. **Issue #2** (`register` warnings in `adclib/tiger.cpp`) — clean compiler
   output. Verify that this is not third-party upstream code we should sync
   instead of patch.
4. **Replace `lua_open()` with `luaL_newstate()`** in `hub/hub.c:128`
   (Lua 5.1 compatible; preparatory step toward Phase 3). New issue to
   be filed when starting work.
5. **Audit hardcoded `"././"` paths** in `core/init.lua` — capture findings,
   may or may not change in Phase 2 depending on scope.
6. **Issue #4** (`+help`/`+myip` deflection) — investigate, fix or close
   as configuration-by-design.
7. **Modernize Windows build** — replaces `compile_with_mingw.bat`. Must
   produce the spec in §3 above. Possibly CMake-based. Largest item in
   Phase 2; likely its own sequence of PRs.

Each item: own GitHub issue (where one does not yet exist), own PR,
own review against the §1 review categories before moving to the next.

**Out of scope for Phase 2** (deferred to later phases):
- Issue #3 (LuaSec bump) → Phase 4
- Lua 5.1 → 5.4 migration → Phase 3
- `cfg.lua` decomposition → Phase 5

## 7. Phase 1 review gate

To be checked before declaring Phase 1 complete and starting Phase 2:

- [x] Linux build green from clean checkout (in WSL native FS)
- [x] Plain-ADC smoketest passes (connect, login, hub responds)
- [x] TLS smoketest passes — TLSv1.3, `TLS_AES_256_GCM_SHA384`
- [x] Build outputs documented (§3)
- [x] Findings logged as GitHub issues (#1, #2, #3, #4, #5)
- [x] No source code modified in Phase 1 (only added: `CLAUDE.md`, `docs/phases/PHASE_1.md`, plus `.gitignore` edit for build/IDE noise)
- [x] Phase 1 doc reviewed by maintainer (2026-05-02)
- [x] Phase 2 entry criteria agreed (ordering as proposed in §6)

Phase 1 is closed. Phase 2 may begin.
