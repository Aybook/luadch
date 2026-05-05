# Luadch v3.1.1

Patch release on top of v3.1.0. Drop-in upgrade: no cfg / on-disk-format
changes, no Lua API changes, no new dependencies. Smoke harness still
10 / 10 PASS on Linux + Windows.

## Highlights

- **Security: DSCH search fanout fixed** ([luadch#200](https://github.com/luadch/luadch/issues/200)).
  `etc_trafficmanager.lua` no longer fans out direct (D / E type) searches
  to every user; the hub's default direct-routing path delivers correctly
  to the single intended SID. Same root cause also clears the AirDC++ 4.21
  "search spam detected" disconnect ([luadch#226](https://github.com/luadch/luadch/issues/226)).
- **Six more upstream-bug fixes** (Interlude 2, rounds 2 + 3): negative DS
  in INF blocked login ([#241](https://github.com/luadch/luadch/issues/241)),
  `+delreg` against blacklisted nicks ([#228](https://github.com/luadch/luadch/issues/228)),
  trafficmanager prefix-script regression ([#240](https://github.com/luadch/luadch/issues/240)),
  forgot-prefix commands in main chat ([#223](https://github.com/luadch/luadch/issues/223)),
  misleading `+help cmd_mass` levels ([#217](https://github.com/luadch/luadch/issues/217)),
  cryptic SSL-context error on first Windows run ([#177](https://github.com/luadch/luadch/issues/177)).
- **Codepoint-aware nick-length check**: `usr_nick_length.lua` now uses
  `utf.len()` so Cyrillic / multi-byte nicks aren't rejected at lower
  codepoint counts than ASCII ones.
- **`hub_inf_manager.lua` failure reason** routed through the per-script
  lang file instead of a hardcoded English string.
- **Smoke harness Windows hang fixed**: `make_cert.bat`'s trailing `pause`
  no longer blocks the harness when run from an interactive shell.
- **Org transfer**: repo now lives at `luadch-ng/luadch` (auto-redirects
  keep historic links working). Project page: <https://luadch-ng.github.io/>.

## Downloads

| File | Platform |
|---|---|
| `luadch-v3.1.1-linux-x86_64.tar.gz` | Linux glibc x86_64 |
| `luadch-v3.1.1-windows-x86_64.zip`  | Windows x86_64 (MinGW UCRT64) |

Extract anywhere and run `./luadch` (Linux) or `Luadch.exe` (Windows). The
trees are self-contained: Lua interpreter, all bundled libs (LuaSec,
LuaSocket, basexx, adclib), default configs, scripts, certs helpers.

Default plain ADC port `5000`, TLS port `5001` after running
`certs/make_cert.{sh,bat}` once. First login: nick `dummy`, password
`test` - **delete that account immediately** after registering yourself,
see [`docs/CONFIGURATION.md`](https://github.com/luadch-ng/luadch/blob/v3.1.1/docs/CONFIGURATION.md).

## Migration from v3.1.0

None required. Drop the new install tree in place of the old one (or
`git pull && cmake --build build && cmake --install build` from source).
`cfg/`, `certs/`, `master.key`, encrypted `user.tbl` carry over without
change.

If you're still on v3.0.0, follow the v3.1.0 migration notes:
<https://github.com/luadch-ng/luadch/releases/tag/v3.1.0>.

## Full changelog

See [`CHANGELOG.md`](https://github.com/luadch-ng/luadch/blob/v3.1.1/CHANGELOG.md)
for the categorised list. Triage notes for the upstream-issue fixes are in
[`docs/phases/INTERLUDE_UPSTREAM_TRIAGE_2.md`](https://github.com/luadch-ng/luadch/blob/v3.1.1/docs/phases/INTERLUDE_UPSTREAM_TRIAGE_2.md).

## Build from source

```sh
git clone --branch v3.1.1 https://github.com/luadch-ng/luadch.git
cd luadch
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
cmake --install build
```

Output lands in `build/install/luadch/` ready to run. Windows needs
`-G "MinGW Makefiles" -DOPENSSL_ROOT_DIR=...` extra, see
[`docs/BUILDING.md`](https://github.com/luadch-ng/luadch/blob/v3.1.1/docs/BUILDING.md).

## Credits

All conceptual credit to **blastbeat** and **pulsar**, original authors of
luadch. This fork modernises and extends their excellent foundation.
