# Building luadch

This document describes how to build luadch from source on Linux, BSD, and
Windows. For a quick reminder of the build commands without the toolchain
setup, see [`CLAUDE.md`](../CLAUDE.md) §4.

---

## Linux / BSD

### Prerequisites

```sh
# Debian / Ubuntu
sudo apt-get install build-essential libssl-dev rsync git

# Fedora / RHEL
sudo dnf install gcc gcc-c++ make openssl-devel rsync git

# FreeBSD / OpenBSD
pkg install gcc rsync git    # OpenSSL is in base
```

### Build

```sh
git clone https://github.com/Aybook/luadch.git
cd luadch
./compile
```

Output lands in `build_$CC/luadch/` (e.g. `build_gcc/luadch/`).

To clean everything:

```sh
./cleanall
```

### Run

```sh
cd build_gcc/luadch
./luadch
```

The hub binds plain ADC on port 5000. To enable TLS on port 5001, run
`certs/make_cert.sh` once (in the build output dir) before starting.

### Known cosmetic build warnings

The Linux build emits **5 deprecation warnings** from the bundled
`luasec/` C sources against system OpenSSL 3.x (`EC_KEY_*`,
`PEM_read_bio_DHparams`, `SSL_CTX_set_tmp_dh_callback`, `EC_KEY_free`,
`DH_free`). These are cosmetic — the functions still exist and work
correctly in current OpenSSL. The negotiated TLS session itself is
modern (TLS 1.3 + AES-256-GCM verified). Tracked in
[issue #3](https://github.com/Aybook/luadch/issues/3) as
`upstream-blocked` / `wontfix`: a real fix requires LuaSec upstream to
migrate to OpenSSL's EVP / provider API, which has not happened yet.

The Windows build (gcc 16) emits 2 stylistic `-Wparentheses` warnings
in `adclib/tiger.cpp` from the third-party Tiger hash code; same
category — cosmetic, not a regression.

---

## Windows (MinGW-w64 + OpenSSL 3.x)

### Required toolchain

luadch builds on Windows via MinGW-w64 (gcc, g++, windres, strip). It does
not require Visual Studio.

| Tool        | Used for                                    |
|-------------|---------------------------------------------|
| MinGW-w64   | C/C++ compilation, linking, resource compile |
| OpenSSL 3.x | LuaSec links against `libssl` / `libcrypto` |

### 1. Install MinGW-w64

The simplest distribution is **WinLibs** (https://winlibs.com/) — a single
zip containing MinGW-w64 with `gcc`, `g++`, `windres`, `strip`, plus
`mingw32-make`. No installer, just unzip.

Recommended:
- Download **GCC 13.x or newer**, **x86_64**, **POSIX threads**, **SEH**
  exception model.
- Extract the archive so that `gcc.exe` lives at:

  ```
  C:\MinGW\bin\gcc.exe
  ```

  (any other location works too — see "Custom paths" below).

Verify:

```cmd
C:\MinGW\bin\gcc.exe --version
```

### 2. Provide OpenSSL 3.x DLLs and headers

`compile_with_mingw.bat` expects to find at `C:\OpenSSL\`:

```
C:\OpenSSL\include\openssl\ssl.h
C:\OpenSSL\libssl-3-x64.dll
C:\OpenSSL\libcrypto-3-x64.dll
```

(plus the rest of the `include\openssl\*.h` headers).

There are several ways to obtain these:

**Option A — cross-compile on Linux/WSL** (matches what the project has
historically used; produces clean, vendor-neutral DLLs):

```sh
sudo apt-get install mingw-w64
git clone https://github.com/openssl/openssl.git
cd openssl
git checkout openssl-3.4.0   # or current 3.x LTS
./Configure --cross-compile-prefix=x86_64-w64-mingw32- mingw64 \
            --prefix=$PWD/dist
make -j$(nproc)
make install
```

Then copy from `dist/` on the Linux side to `C:\OpenSSL\` on Windows:

```sh
mkdir -p /mnt/c/OpenSSL
cp -r dist/include/openssl /mnt/c/OpenSSL/include/
cp dist/bin/libssl-3-x64.dll /mnt/c/OpenSSL/
cp dist/bin/libcrypto-3-x64.dll /mnt/c/OpenSSL/
```

**Option B — pre-built distribution** (faster but third-party):

Sources like Shining Light Productions (slproweb.com) ship Windows
OpenSSL builds. Download the **MinGW** flavour (not the MSVC one) and
arrange the files into the layout shown above.

### 3. Build

From the repository root:

```cmd
compile_with_mingw.bat
```

Output lands in `build_mingw\luadch\`.

### Custom paths

If your toolchain is **not** at `C:\MinGW` and `C:\OpenSSL`, set
environment variables before running the script:

```cmd
set LUADCH_MINGW_DIR=D:\Tools\winlibs-mingw64
set LUADCH_OPENSSL_DIR=D:\Tools\openssl-3.4-mingw
compile_with_mingw.bat
```

These can also be set persistently via `setx LUADCH_MINGW_DIR …` or via
**System Properties → Environment Variables**.

### Sanity checks

If the script can't find any of `gcc.exe`, the OpenSSL header, or the
two OpenSSL DLLs, it exits with a clear error message naming the missing
file and the env-var that overrides its location. There is no need to
hunt through the build output.

### Run

After a successful build:

```cmd
cd build_mingw\luadch
Luadch.exe
```

Plain ADC on port 5000, optional TLS on port 5001 once
`certs\make_cert.bat` has been run once.

---

## Cross-platform notes

- The build output layout is identical between Linux and Windows except
  that Linux produces `luadch` / `liblua.so` / `*.so` and Windows produces
  `Luadch.exe` / `lua.dll` / `*.dll`. See
  [`docs/phases/PHASE_1.md`](phases/PHASE_1.md) §3 for the authoritative
  artifact list.

- The `*.c.not` rename trick in the Windows build (around the LuaSocket
  step) is a known workaround for excluding Unix-only sources. It will
  go away with the planned CMake migration (see
  [issue #15](https://github.com/Aybook/luadch/issues/15)).

- For continuous integration setups, the same env-var approach above
  works in GitHub Actions / GitLab CI / etc. — pin both vars in your
  workflow definition and the rest is reproducible.
