# Changelog

All notable changes to the `Aybook/luadch` fork are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The upstream project (`luadch/luadch`) is a separate codebase; its release
history is at https://github.com/luadch/luadch/releases.

## [Unreleased]

## [v3.0.0] - 2026-05-03

First release of the modernised `Aybook/luadch` fork. Forked from upstream
`luadch/luadch` source `v2.24 [RC4]`; upstream's last public release was
`v2.23` (2022-04-02).

This release lifts the project off Lua 5.1 (EOL since 2012), replaces the
ad-hoc Linux/Windows shell+batch build pipeline with a single CMake build,
and ships several pre-existing-bug fixes on top.

### Breaking changes

- **Lua runtime upgraded from 5.1.5 to 5.4.7.** Plugins relying on
  `setfenv`, `getfenv`, `loadstring`, `unpack`, `module(...)`, `math.atan2`,
  `math.pow`, `math.log10`, `LUA_MAXCAPTURES`, etc. will not load - update
  to 5.4 idioms (`load`, `table.unpack`, explicit `_ENV`, `math.atan` two-arg
  form).
- **Build system replaced with CMake.** The old `compile` shell script and
  `compile_with_mingw.bat` are gone (including the `*.c.not` source-rename
  hack). The new build is `cmake -B build && cmake --build build && cmake --install build`
  on every supported platform.
- **`slnunicode` C module replaced by a 40-line pure-Lua shim** built on
  Lua 5.4's builtin `utf8` library. Same surface API as the old `unicode`
  table; pattern-matching call sites confirmed ASCII-only by audit. Plugins
  using non-trivial Unicode-class patterns (`%l` against German umlauts,
  etc.) would need a dedicated function added to the shim.

### Added

- CMake build system covering Linux x86_64, Windows x86_64 (MinGW UCRT),
  and ARM aarch64 (cross-compile from Linux). Same three-step pipeline
  on every platform.
- GitHub Actions release workflow that builds Linux + Windows binaries
  and attaches them to the GitHub release on tag push.
- `.gitattributes` enforcing platform-correct line endings (CRLF for
  `.bat` / `.cmd`; LF everywhere else).
- `docs/BUILDING.md` rewritten with platform-specific Linux / Windows /
  ARM sections, OpenSSL cross-compile recipe, ARM cross-toolchain setup.
- `docs/INSTALLING.md`: deployment guide (Linux service-user pattern,
  systemd unit, Windows NSSM service, backups, update procedure).
- `docs/CONFIGURATION.md`: post-install configuration reference (first-run
  checklist, cfg.tbl tour, plugin categories, troubleshooting).
- `docs/phases/PHASE_{1..5}.md` and `INTERLUDE_UPSTREAM_TRIAGE.md`:
  per-phase modernisation journals.
- New `msg_del_reason` template in `cmd_delreg.lua` so deleted users see
  the reason on disconnect (en + de language files updated).

### Changed

- Hub launcher `hub/hub.c`: `lua_open()` -> `luaL_newstate()` (5.4 API).
- `adclib/adclib.cpp`: `luaL_reg` -> `luaL_Reg`,
  `luaL_register` -> `luaL_newlib + return 1`.
- Windows build: `wmic` calls in `cmd_hubinfo.lua` replaced with
  PowerShell `Get-CimInstance` (Windows 11 24H2+ removed `wmic`).
- CMake's Windows OpenSSL DLL bundling now searches both flat
  (`$ROOT/`) and bin-subdir (`$ROOT/bin/`) layouts so msys2 UCRT64 and
  WinLibs / ShiningLight Win64 both work without manual flattening.

### Fixed

- `os.difftime` 1-arg call pattern (silently tolerated in 5.1, errors in
  5.4): 12 scripts updated to `os.time() - x`.
- `cmd_hubinfo.lua` crash on missing certificate file (`get_certinfos`
  missing return).
- `+!#` server commands sent as PMs to the hubbot now route through the
  command pipeline again
  ([PR #13](https://github.com/Aybook/luadch/pull/13)).
- `make_cert.sh`: `UID` variable collision with bash's read-only builtin -
  renamed to `RAND_ID`.
- `make_cert.bat`: silently produced certs with an empty CN on
  OpenSSL 3.5+ because `openssl rand -hex 16 -out X` requires the
  positional `<num>` last; reordered. Also dropped OpenSSL-1.0.x-era
  `RANDFILE` legacy.
- `register` keyword warnings in `adclib/tiger.cpp` (C++17 deprecation).
- `cmd_delreg.lua` help-text fallback corrected: "delregs an existing
  user".
- `cmd_usercleaner.lua`: `+usercleaner showghosts` crashed when any
  registered user lacked a `date` attribute - guard `reg_date` before
  comparison.
- `usr_uptime.lua`: crashed on first user login after the database file
  was missing or unparseable - removed the `else` branch that returned
  early with an empty table before the entry-setup ran.
- `+delreg <nick> <reason>` now relays the reason to the deleted user
  before kicking, instead of the silent generic "You were delregged."
- `+shutdown` and `+restart` countdowns now block main-chat broadcasts so
  users cannot type during the countdown.

### Removed

- Legacy build scripts: `compile`, `compile_with_mingw.bat`, `cleanall`.
- The `*.c.not` rename trick the Windows build used to skip Unix-only
  LuaSocket sources.
- Unmaintained `slnunicode` C module (1366 lines of C, replaced by the
  40-line Lua shim).

### Security

- TLS 1.3 + AES-256-GCM verified end-to-end after the modernisation.
- `cfg/cfg.tbl` and `cfg/user.tbl` documented as 0600 by deployment
  guide (they hold the default-account password and the registered-user
  hashes respectively).

### Phase journals

For the full per-phase narrative (activities, design decisions, build
output specs, review-gate checklists), see [`docs/phases/`](docs/phases/).

[Unreleased]: https://github.com/Aybook/luadch/compare/v3.0.0...HEAD
[v3.0.0]: https://github.com/Aybook/luadch/releases/tag/v3.0.0
