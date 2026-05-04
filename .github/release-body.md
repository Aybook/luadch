# Luadch v3.0.0

First release of the modernised `Aybook/luadch` fork.

## Highlights

- **Lua 5.1 -> 5.4** (5.1 reached EOL in 2012)
- **Single CMake build** for Linux, Windows, and ARM aarch64
- **Pre-built binaries** for Linux x86_64 and Windows x86_64 attached below
- TLS 1.3 + AES-256-GCM verified end-to-end
- Three new docs: `BUILDING.md`, `INSTALLING.md`, `CONFIGURATION.md`
- Six bug fixes from the upstream tracker plus several local discoveries

## Downloads

| File | Platform |
|---|---|
| `luadch-v3.0.0-linux-x86_64.tar.gz` | Linux glibc x86_64 |
| `luadch-v3.0.0-windows-x86_64.zip` | Windows x86_64 (MinGW UCRT64) |

Extract anywhere and run `./luadch` (Linux) or `Luadch.exe` (Windows). The
trees are self-contained: Lua interpreter, all bundled libs (LuaSec,
LuaSocket, basexx, adclib), default configs, scripts, certs helpers.

Default plain ADC port `5000`, TLS port `5001` after running
`certs/make_cert.{sh,bat}` once. First login: nick `dummy`, password `test` -
**delete that account immediately** after registering yourself, see
[`docs/CONFIGURATION.md`](https://github.com/Aybook/luadch/blob/v3.0.0/docs/CONFIGURATION.md).

## Breaking changes for existing deployments

- **Plugin authors**: Lua 5.4 idioms required (`load` instead of
  `loadstring`, explicit `_ENV` instead of `setfenv`, `table.unpack`
  instead of `unpack`, `math.atan` two-arg form instead of `math.atan2`,
  etc.).
- **Build instructions**: now `cmake -B build && cmake --build build && cmake --install build`
  on every platform. The legacy `compile` shell script and
  `compile_with_mingw.bat` are gone.
- **slnunicode**: replaced by a Lua shim. Plugins relying on Unicode-class
  patterns (e.g. `%l` matching German umlauts) need a dedicated function
  added to the shim - the bundled scripts use ASCII-only patterns and
  needed no changes.

## Full changelog

See [`CHANGELOG.md`](https://github.com/Aybook/luadch/blob/v3.0.0/CHANGELOG.md)
for the complete list, organised by category.

## Build from source

The pipeline is identical on every supported platform:

```sh
git clone --branch v3.0.0 https://github.com/Aybook/luadch.git
cd luadch
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
cmake --install build
```

Output lands in `build/install/luadch/` ready to run. Windows needs
`-G "MinGW Makefiles" -DOPENSSL_ROOT_DIR=...` extra, see
[`docs/BUILDING.md`](https://github.com/Aybook/luadch/blob/v3.0.0/docs/BUILDING.md).

## Credits

All conceptual credit to **blastbeat** and **pulsar**, original authors of
luadch. This fork modernises and extends their excellent foundation.
