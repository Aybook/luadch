# CLAUDE.md

Context for Claude Code (and any AI assistant) working on luadch. Read this before
making changes — it captures the working agreement, architecture, and modernization plan
that span sessions.

User communication is in **German**; all written artifacts (this file, code, comments,
commits, PRs, issues) stay in **English** so other contributors can read them.

---

## 1. Working agreement (non-negotiable)

These rules are set by the maintainer and apply to every change.

1. **Security and consistency come first.** Treat any change touching network I/O,
   authentication, ADC protocol parsing, or configuration as security-sensitive. When
   fixing a pattern in one place, grep for the same pattern across the repo and fix it
   everywhere — divergent code paths are a defect.
2. **No spaghetti code.** Prefer small, focused functions and modules. Don't grow
   `core/cfg.lua` or `core/hub.lua` further; if new logic doesn't have an obvious home,
   propose a new module before writing the code.
3. **One phase at a time.** Work proceeds strictly phase by phase (see §5 Roadmap). Do
   not pull tickets forward from a later phase, even if they look trivial.
4. **Review gate between phases.** After every phase, run an explicit review covering:
   - **Security** — input validation, auth boundaries, network surface, file I/O.
   - **Consistency** — did similar code paths drift apart? Did naming get inconsistent?
   - **Code quality** — readability, dead code, duplication, function length.
   - **Build & smoke test** — both Linux and Windows builds succeed, hub starts, a
     test client (`adc://127.0.0.1:5000`) can connect.
5. **Fix-then-advance.** Anything found in the review must be fixed before the next
   phase begins. No "we'll get back to it." If something is genuinely out of scope,
   open a tracking issue and link it from the phase summary.
6. **Small reviewable PRs.** One logical change per PR. Reference the GitHub issue it
   closes. Never bundle modernization work with unrelated fixes.

When uncertain whether a change fits the current phase, **stop and ask the maintainer**.

---

## 2. Project overview

luadch is a DC++ **ADC** hub server written in Lua with a thin C launcher
(`hub/hub.c`, 209 lines) that embeds the Lua interpreter and hands off to
`core/init.lua`.

- **Current source version:** `v2.24 [RC4]` (see `core/const.lua`)
- **Latest release:** `v2.23` (2022-04-02) — the source is ahead of the last release
- **Open issues:** 47 (as of 2026-05-02)
- **License:** GPLv3.0

The repo bundles all runtime dependencies as source — there is no external package
manager. This is intentional (the project ships as a self-contained build) but means
dependency updates are manual.

### Bundled dependencies (verified 2026-05-03)

| Component   | Bundled version | Path           | Notes                                |
|-------------|-----------------|----------------|--------------------------------------|
| Lua         | **5.4.7**       | `lua/`         | bumped from 5.1.5 in Phase 3         |
| LuaSec      | **1.3.2**       | `luasec/`      | TLS support, links against OpenSSL — Phase 4 bump candidate |
| LuaSocket   | **3.1.0**       | `luasocket/`   | TCP/UDP, IPv6 capable — Phase 4 bump candidate |
| basexx      | (no version)    | `basexx/`      | Pure Lua, base32/64 encoding         |
| unicode     | shim            | `slnunicode/unicode.lua` | ~40-line Lua shim that replaces the unmaintained slnunicode C module; uses `string.X` and Lua 5.4 builtin `utf8` |
| adclib      | (no version)    | `adclib/`      | C module: ADC hashing & escaping     |

---

## 3. Architecture

### Boot sequence

```
hub/hub.c           ── lua_open(), register C functions, load core/init.lua
  └─ core/init.lua  ── sandboxed env, load libs + core modules in order
       └─ core/hub.lua      ── hub.loop() — main event loop
            └─ core/server.lua ── select() loop over sockets, SSL wrap
```

### Core modules (line counts)

| Module               | LOC  | Responsibility                                       |
|----------------------|------|------------------------------------------------------|
| `core/const.lua`     |   21 | Program name, version, config paths                  |
| `core/hci.lua`       |    9 | Stub (purpose unclear — flag for review)             |
| `core/test.lua`      |   14 | Stubbed; **no active test suite**                    |
| `core/mem.lua`       |   32 | GC trigger                                           |
| `core/signal.lua`    |   41 | Timers / start time                                  |
| `core/out.lua`       |   99 | Logging, error output, listener registry             |
| `core/types.lua`     |  159 | ADC protocol type validation                         |
| `core/init.lua`      |  209 | Bootstrap: env, module load order, restart loop      |
| `core/scripts.lua`   |  263 | Plugin loader, sandbox, hook registry                |
| `core/doc.lua`       |  308 | Auto-doc generation (currently disabled)             |
| `core/util.lua`      |  686 | File I/O, encoding, UTF-8, table helpers             |
| `core/adc.lua`       |  926 | ADC protocol: parse, escape, format                  |
| `core/server.lua`    |  989 | Network: select loop, SSL, coroutines                |
| `core/hub.lua`       | 2239 | **Hot path** — login, messaging, commands, listeners |
| `core/cfg.lua`       | 3688 | **Largest** — config + user.tbl + language           |
| `hub/hub.c`          |  209 | C launcher, signal handling                          |

### Plugin / hook model

Plugin scripts live in `scripts/` and are loaded via `core/scripts.lua` into a
sandboxed environment. They register listeners on lifecycle events:

- `onStart` — script init
- `onLogin` — user finished login
- `onFailedAuth` — auth failure
- `onBroadcast` — main-chat message
- `onReg` / `onDelreg` — registration changes
- `onError` — script error
- `onExit` — hub shutdown

Plugins use the `hub` table API: `hub.getuser(nick)`, `hub.broadcast(msg)`,
`hub.setlistener(event, id, func)`, plus `cfg.get(key)`, `utf.sub()`, etc.

---

## 4. Build & run

### Linux / BSD

```bash
./compile        # detects platform & compiler, builds into build_$CC/
./cleanall       # remove all build artifacts
```

The script builds in order: lua → adclib → slnunicode → luasocket → luasec → basexx → hub.

### Windows (MinGW)

```cmd
compile_with_mingw.bat
```

The toolchain locations are read from `LUADCH_MINGW_DIR` and `LUADCH_OPENSSL_DIR`
(defaults: `C:\MinGW`, `C:\OpenSSL`). If either is missing the script prints a
clear error before any compilation runs.

The Windows build still uses a `*.c.not` rename trick to exclude Unix-only
LuaSocket sources. That goes away with the CMake migration (issue #15).

**Full toolchain setup (download links, OpenSSL cross-compile, custom paths):
see [`docs/BUILDING.md`](docs/BUILDING.md).**

### First-time login

```
Nick:     dummy
Password: test
Address:  adc://127.0.0.1:5000      (plain)
          adcs://127.0.0.1:5001     (TLS, after running certs/make_cert.{sh,bat})
```

After login: `+reg <yournick> 100`, then `+delreg dummy`, then `+reload`.

---

## 5. Modernization roadmap

Each phase ends with the §1.4 review gate. We do not start Phase N+1 until Phase N
is reviewed and clean.

### Phase 1 — Foundation (current)

**Goal:** Reproducible builds on Linux and Windows, smoke test passes, baseline
documented.

- [ ] Verify Linux build from clean checkout
- [ ] Verify Windows MinGW build from clean checkout (note: hardcoded paths)
- [ ] Smoke-test: hub starts, dummy login works on plain + TLS
- [ ] Document any deviations from this CLAUDE.md
- [ ] Capture exact toolchain versions used

**Out of scope for Phase 1:** changing any `.lua` or `.c` file. This phase is
"observe and document," not "modify."

**Review gate:** Both builds produce a working hub. Build instructions in this file
match reality. No code changed yet.

### Phase 2 — Quick wins (no breaking changes)

**Goal:** Pick off small, low-risk issues that improve consistency without changing
behavior. Includes a minimal Windows-build hardening (ENV-var paths) so the existing
toolchain is reproducible. **Full Windows-build modernization (CMake) is its own
phase — see Phase 5 below.**

Candidates (planned at start of phase; actual progress tracked via merged PRs):
- Repo line-ending policy (`.gitattributes`)
- Replace deprecated `lua_open()` with `luaL_newstate()` in `hub/hub.c`
- C++17 `register`-keyword warnings in `adclib/tiger.cpp`
- `make_cert.sh` `UID`-variable collision with bash builtin
- Route `+!#` server commands from PM-to-hubbot through the command pipeline
- Audit hardcoded `"././"` relative paths in `core/init.lua` (audit only;
  full fix deferred to Phase 6)
- **Make Windows build reproducible:** replace hardcoded `C:\MinGW` and
  `C:\OpenSSL` paths in `compile_with_mingw.bat` with ENV variables, sanity
  check toolchain, document prereqs in `docs/BUILDING.md`

**Review gate:** Build still green on both platforms. Smoke test passes. No new
warnings. Each change has a PR + closed issue.

### Phase 3 — Lua 5.1 → 5.4 migration

**Goal:** Move embedded interpreter from Lua 5.1.5 (EOL 2012) to Lua 5.4.

This is the biggest single change in the modernization. Scope it carefully:
- Replace `setfenv` / `getfenv` (used in `core/init.lua`, `core/scripts.lua`) with
  `_ENV` and explicit closures
- `loadstring` → `load`
- `unpack` → `table.unpack`
- `module(...)` if used anywhere
- C API changes in `hub/hub.c` and the C modules (`adclib`, `slnunicode`)
- Compatibility re-check of all bundled libs against Lua 5.4

**Review gate:** All 70+ scripts in `scripts/` load and run. ADC protocol smoke tests
pass. Plugin sandbox still isolates globals. Performance not visibly worse.

### Phase 4 — Dependency updates

**Goal:** Bump bundled deps to current upstream where compatible with Phase 3 result.

- LuaSec 1.3.2 → current
- LuaSocket 3.1.0 → current
- basexx, slnunicode, adclib — assess

**Review gate:** TLS handshake works with modern clients (AirDC++ current). No
regressions in chat / commands.

### Phase 5 — Cross-platform build system (CMake migration)

**Goal:** Replace the ad-hoc `compile` shell script and the fragile
`compile_with_mingw.bat` (with its `*.c.not` rename hack) with a single
CMake-based build that produces the same artifact layout on Linux and Windows.

Why this comes after Phase 4: the Lua-5.4 migration (Phase 3) and the dep
bumps (Phase 4) change which Lua API symbols and which `lib*` variants we
link against. Doing CMake first would mean re-doing the configuration once
those land.

In scope:
- One `CMakeLists.txt` per module + a top-level orchestrator
- Single source-of-truth for the artifact layout captured in
  `docs/phases/PHASE_1.md` §3
- Drop the `*.c.not` rename trick — exclude Unix sources via CMake's
  per-platform source lists instead
- Toolchain finders for OpenSSL, Lua, etc.
- Optional: GitHub Actions CI matrix (Ubuntu + Windows MinGW) so future
  PRs get build verification automatically

**Review gate:** Both platforms build via `cmake --build`; output layout matches
the Phase 1 acceptance contract; smoke tests pass on both; the legacy `compile`
and `compile_with_mingw.bat` are removed (or kept as thin shims that call CMake,
if the maintainer prefers the old commands as muscle memory).

### Phase 6 — Refactor & tests

**Goal:** Address structural debt now that the runtime, dependencies, and build
system are current.

- Split `core/cfg.lua` (3688 lines) by domain
- Untangle hot paths in `core/hub.lua`
- Anchor runtime paths to binary/script location (Issue #12) instead of CWD
- Build a minimal smoke-test suite (replacing the stub `core/test.lua`)
- Address remaining `TODO` / `FIXME` comments

**Review gate:** Test suite green. No module exceeds an agreed line ceiling. No
function exceeds an agreed complexity ceiling. CI can run the smoke tests.

---

## 6. External state & memory

- **Phase journals** — [`docs/phases/`](docs/phases/) holds one Markdown file per
  modernization phase: activities, findings, build-output specs, and the review-gate
  checklist. Entry point for "what happened in phase N" is `docs/phases/PHASE_N.md`.
  These are the narrative — issues and code are the actionable state.
- **GitHub issues** — https://github.com/Aybook/luadch/issues — the actionable backlog.
  Each finding from a phase journal that needs work is an issue here, labeled with the
  target phase (`phase-2`, `phase-3`, …). Use `gh issue list --label phase-2` to scope
  upcoming work. Upstream `luadch/luadch` issues are referenced selectively when we
  adopt one (no bulk import — see §6 *Upstream policy* below).
- **Auto-memory** — Claude's per-user auto-memory directory for this project — holds
  user profile and high-level context. Architecture / build / roadmap details live in
  **this file**, not in memory, because they belong with the code.
- **Releases** — last public release is v2.23 (2022-04-02). Source is at v2.24 RC4.

### Upstream policy

The repo at `Aybook/luadch` is currently a fork of `luadch/luadch`. The upstream is
not actively released (last release 2022-04-02) but still receives occasional commits.
We do **not** plan to push modernization work back upstream and do **not** bulk-import
upstream's open issues. When a phase touches an area covered by an upstream issue, we
open a fresh issue here that references the upstream one in its body.

---

## 7. Conventions for changes

- **Commit style:** match `git log` — concise, imperative, optional `fix #NNN` trailer.
- **PR scope:** one issue per PR, except for tightly coupled changes.
- **Lua style:** match the file you're editing. Don't reformat unrelated lines.
- **Comments:** explain *why*, not *what*. Don't add a comment that just restates code.
- **No drive-by refactors.** If you spot something during an unrelated change, open
  an issue instead of fixing it inline.
