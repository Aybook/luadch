# Luadch v3.1.2

Patch release on top of v3.1.1. Drop-in upgrade: no cfg / on-disk-format
changes, no Lua API changes. Single fix; smoke harness now 11 / 11
PASS on Linux + Windows.

## Highlights

- **Canonical LuaSocket / LuaSec install layout** (closes
  [#88](https://github.com/luadch-ng/luadch/issues/88)). Plugins doing
  `require "socket.http"` or `require "ssl.https"` now load drop-in
  instead of failing because the bundle was installed flat. Source
  files unchanged; only the install-tree layout flips. Hub-internal
  usage unaffected (only the entrypoints `socket.lua` / `ssl.lua` are
  required, both stay top-level).
- **Smoke regression test** added so future CMake changes can't drift
  back to the flat bundling without the smoke gate firing.

## What this unblocks

- [`luadch-ng/scripts ptx_RSSFeedWatch`](https://github.com/luadch-ng/scripts)
  loads drop-in now (previously needed an operator-side manual
  rearrangement of `lib/`).
- Future plugins using canonical Lua HTTP/HTTPS idiom load without
  any luadch-specific workarounds.
- Phase-8+ feature work that needs HTTP (REST API, Prometheus
  exporter, AbuseIPDB integration) starts from canonical assumptions.

## Downloads

| File | Platform |
|---|---|
| `luadch-v3.1.2-linux-x86_64.tar.gz` | Linux glibc x86_64 |
| `luadch-v3.1.2-windows-x86_64.zip`  | Windows x86_64 (MinGW UCRT64) |

Extract anywhere and run `./luadch` (Linux) or `Luadch.exe` (Windows).
The trees are self-contained: Lua interpreter, all bundled libs (LuaSec,
LuaSocket, basexx, adclib), default configs, scripts, certs helpers.

Default plain ADC port `5000`, TLS port `5001` after running
`certs/make_cert.{sh,bat}` once. First login: nick `dummy`, password
`test` - **delete that account immediately** after registering yourself,
see [`docs/CONFIGURATION.md`](https://github.com/luadch-ng/luadch/blob/v3.1.2/docs/CONFIGURATION.md).

## Migration from v3.1.1

None required. Drop the new install tree in place of the old one (or
`git pull && cmake --build build && cmake --install build` from
source). `cfg/`, `certs/`, `master.key`, encrypted `user.tbl` carry
over without change.

If you had previously hand-rearranged `lib/luasocket/lua/socket/` to
get an HTTP plugin to work, the new install tree already provides
that layout - your manual rearrangement is now redundant but harmless.

If you're still on v3.1.0 or earlier, follow the v3.1.0 migration
notes: <https://github.com/luadch-ng/luadch/releases/tag/v3.1.0>.

## Full changelog

See [`CHANGELOG.md`](https://github.com/luadch-ng/luadch/blob/v3.1.2/CHANGELOG.md)
for the categorised list.

## Build from source

```sh
git clone --branch v3.1.2 https://github.com/luadch-ng/luadch.git
cd luadch
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
cmake --install build
```

Output lands in `build/install/luadch/` ready to run. Windows needs
`-G "MinGW Makefiles" -DOPENSSL_ROOT_DIR=...` extra, see
[`docs/BUILDING.md`](https://github.com/luadch-ng/luadch/blob/v3.1.2/docs/BUILDING.md).

## Credits

All conceptual credit to **blastbeat** and **pulsar**, original authors of
luadch. This fork modernises and extends their excellent foundation.
