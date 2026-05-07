# Luadch v3.1.4

Patch release on top of v3.1.3. Drop-in upgrade: no cfg / on-disk-format changes, no Lua API changes. Smoke harness 12 / 12 PASS on Linux + Windows. **First release with an official container image.**

## Highlights

- **Pure-rootless container image** (closes [#87](https://github.com/luadch-ng/luadch/issues/87)). Multi-stage Alpine 3.20, runs as UID/GID 1000 by default - no `s6-overlay`, no `gosu`, no PUID/PGID entrypoint magic. Operators override at run time via Docker's built-in `--user` flag. Multi-arch images on `ghcr.io/luadch-ng/luadch` (linux/amd64 + linux/arm64). Self-signed cert + keyprint generated and logged on first start, master.key on a separate `/secrets` mount per the F-AUTH-1 backup-separation recommendation. Compose file at the repo root, full operator guide at [`docs/DOCKER.md`](https://github.com/luadch-ng/luadch/blob/v3.1.4/docs/DOCKER.md).
- **`kill_wrong_ips` defaults to `true`** (closes [#97](https://github.com/luadch-ng/luadch/issues/97)). A connecting client whose INF advertises an IP different from the TCP source is now disconnected; same check fires on post-login INF updates via `hub_inf_manager` (`I4`/`I6` added to `forbidden.flags_on_inf`). Per-IP rate limits, GeoIP rules, the unified blocklist, and abuse logs are no longer blinded by IP-spoofing INFs. Operator opt-out for NAT-weird deployments documented in [`docs/SECURITY.md` § 5](https://github.com/luadch-ng/luadch/blob/v3.1.4/docs/SECURITY.md).
- **`etc_motd` multi-placeholder fix** (closes [#103](https://github.com/luadch-ng/luadch/issues/103)). MOTDs that use the nick placeholder more than once (e.g. bilingual greetings) no longer crash the `onLogin` listener with `bad argument #3 to 'format' (no value)`. New `{nick}` template form is the recommended placeholder; legacy `%s` is still accepted.

## What this unblocks

- One-line container deployment for first-time operators: `docker compose up -d`.
- The audit deferral for IP-spoofing INFs is closed; combined with v3.1.3's encryption-bypass + DoS fixes, the post-Phase-7 audit batch ([#98](https://github.com/luadch-ng/luadch/issues/98)) is fully resolved except for the password-reply-paths UX call ([#95](https://github.com/luadch-ng/luadch/issues/95), Phase-8).

## Downloads

| File | Platform |
|---|---|
| `luadch-v3.1.4-linux-x86_64.tar.gz` | Linux glibc x86_64 |
| `luadch-v3.1.4-windows-x86_64.zip`  | Windows x86_64 (MinGW UCRT64) |
| `ghcr.io/luadch-ng/luadch:v3.1.4`   | Container, linux/amd64 + linux/arm64 |

Extract the binary tarball / zip anywhere and run `./luadch` (Linux) or `Luadch.exe` (Windows). The trees are self-contained: Lua interpreter, all bundled libs (LuaSec, LuaSocket, basexx, adclib), default configs, scripts, certs helpers.

For Docker:

```sh
git clone --branch v3.1.4 https://github.com/luadch-ng/luadch.git
cd luadch
cp .env.example .env   # adjust PUID / PGID if `id -u` is not 1000
mkdir -p cfg scripts certs log secrets
docker compose up -d
```

The container's entrypoint seeds empty mounts, generates the TLS cert, and logs the keyprint on first start. See [`docs/DOCKER.md`](https://github.com/luadch-ng/luadch/blob/v3.1.4/docs/DOCKER.md) for the full operator guide.

## Migration from v3.1.3

None required. Drop the new install tree in place of the old one (or `git pull && cmake --build build && cmake --install build` from source). `cfg/`, `certs/`, `master.key`, encrypted `user.tbl` carry over without change.

The `kill_wrong_ips = true` default is the only behaviour change. Most deployments are unaffected (the legitimate `I40.0.0.0` passive-mode case is still allowed; the hub fills in the real IP). If you have users behind symmetric NAT / CGNAT / dual-stack-mismatch / TLS-terminating proxies who were previously surviving the auth flow with mismatched INF IPs, set `kill_wrong_ips = false` in your `cfg/cfg.tbl`. Full rationale in [`docs/SECURITY.md` § 5](https://github.com/luadch-ng/luadch/blob/v3.1.4/docs/SECURITY.md).

If you're still on v3.1.2 or earlier, follow the v3.1.2 / v3.1.3 migration notes:
<https://github.com/luadch-ng/luadch/releases>

## Full changelog

See [`CHANGELOG.md`](https://github.com/luadch-ng/luadch/blob/v3.1.4/CHANGELOG.md) for the categorised list.

## Build from source

```sh
git clone --branch v3.1.4 https://github.com/luadch-ng/luadch.git
cd luadch
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
cmake --install build
```

Output lands in `build/install/luadch/` ready to run. Windows needs `-G "MinGW Makefiles" -DOPENSSL_ROOT_DIR=...` extra, see [`docs/BUILDING.md`](https://github.com/luadch-ng/luadch/blob/v3.1.4/docs/BUILDING.md).

## Credits

All conceptual credit to **blastbeat** and **pulsar**, original authors of luadch. This fork modernises and extends their excellent foundation.
