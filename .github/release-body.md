# Luadch v3.1.9

**Maintenance patch release** on the `release/3.1.x` line. Three bug fixes (two restoring spec-compliant hublist visibility, one defense-in-depth) plus a new pre-compiled `linux-aarch64` release artifact for Raspberry Pi. No breaking changes; no cfg / lang-file changes; drop-in upgrade from v3.1.8.

## ⚠️ Before upgrading

Back up your `cfg/`, `scripts/lang/`, `scripts/data/`, `scripts/cfg/`, `certs/`, and `secrets/` directories before any upgrade, on principle. **This release has no required cfg or lang-file changes** - the upgrade is a pure binary / script tree swap, but the backup discipline is worth keeping.

```sh
tar -czf "luadch-backup-$(date +%F).tar.gz" cfg scripts certs secrets
```

## Why upgrade

**Public hubs on v3.1.8 are effectively invisible to ADC hublist pingers.** The PING HSUP handler errored out silently ([#162](https://github.com/luadch-ng/luadch/issues/162)) and even when it didn't, the BINF validation rejected pinger clients that legitimately omitted `I4` / `I6` ([#161](https://github.com/luadch-ng/luadch/issues/161)). Both fixes restore hublist visibility on public hubs.

**Reg-only (private) hubs** are unaffected by #161 / #162 in operator-visible ways but still benefit from the #160 defense-in-depth and the `core/server.lua` latent-bug closure. Upgrade is recommended for all operators regardless of hub mode.

## Bugfixes

### [#161](https://github.com/luadch-ng/luadch/issues/161) - BINF without `I4` / `I6` was rejected

Per ADC 4.3.x the `I4` / `I6` fields are *conditionally* required (only when the client advertises TCP4 / UDP4 / TCP6 / UDP6 in `SU`). Hublist pingers and any IP-agnostic probe legitimately omit them. The hub now treats a missing `I4` / `I6` like the spec-defined `0.0.0.0` placeholder - fills in the TCP-source IP under the connection's address family, no special-case "no-IP user" shape downstream. `kill_wrong_ips` spoof-detection is **unchanged** for actually-mismatched claims.

Mirrors upstream [luadch/luadch#176](https://github.com/luadch/luadch/issues/176).

### [#162](https://github.com/luadch-ng/luadch/issues/162) - PING HSUP handler crashed silently on public hubs

A T1.3 regression introduced in v3.1.8 by [#147](https://github.com/luadch-ng/luadch/issues/147): the new SS / SF aggregator loop called `pairs( _normalstatesids )` but `pairs` was not imported into the `core/hub_dispatch.lua` sandbox locals. Every ADC PING handshake against a `reg_only = false` hub hit the sandbox guard, the dispatcher errored out per-connection (caught by the hub's pcall, logged to `error.log`), and the pinger saw zero frames.

Reg-only hubs were unaffected because the `_cfg_reg_only` short-circuit prevented the aggregator from running.

### [#160](https://github.com/luadch-ng/luadch/issues/160) (Sopor) - `etc_trafficmanager` defense-in-depth

The `onSearch` listener already swallows searches in both directions for blocked users, so a blocked user normally has no search to reply to. The new `onSearchResult` listener catches the protocol-violating edge case where a blocked user sends an unsolicited DRES / FRES (or a DRES targets a blocked user). Plugin bumped to v2.2.

### Latent crash in `core/server.lua` `changesettings()`

`tonumber()` called seven times without `local tonumber = use "tonumber"` import. Function is currently dead code (no caller in hub or plugins) so no production impact; surfaced by the #162 sandbox-locals audit. Fix is a one-line `use` declaration.

## Features

### [#159](https://github.com/luadch-ng/luadch/issues/159) (Sopor) - pre-compiled `linux-aarch64` Raspberry Pi binary

New release artifact `luadch-v3.1.9-linux-aarch64.tar.gz` alongside the existing `linux-x86_64` and `windows-x86_64` builds. Native arm64 build on GitHub's `ubuntu-24.04-arm` runner - no cross-compile.

Covers Raspberry Pi 3+ / 4 / 5 / Zero 2W with a 64-bit OS (>95% of the active Pi installed base in 2026). 32-bit ARM (Pi 1 / Zero v1 / Pi 2 32-bit) still requires the source build per [`docs/BUILDING.md`](https://github.com/luadch-ng/luadch/blob/release/3.1.x/docs/BUILDING.md).

## Notes

- **No breaking changes, no cfg / lang-file edits required.** Drop-in upgrade from v3.1.8.
- **Pre-merge review pattern.** All three bugfixes were caught by a two-pass review (independent agent + self-spot-check) that was codified during this cycle. The review also surfaced the `core/server.lua` `tonumber` latent bug as a sibling-module audit finding.
- **3.1.x line still on security-fixes-only.** v3.1.9 is a maintenance release; new feature work continues on the 3.2.x line on `master` per [`CLAUDE.md` §8](https://github.com/luadch-ng/luadch/blob/master/CLAUDE.md#8-release-lines-and-support-policy).

## Downloads

| File | Platform |
|---|---|
| `luadch-v3.1.9-linux-x86_64.tar.gz`  | Linux glibc x86_64 |
| `luadch-v3.1.9-linux-aarch64.tar.gz` | Linux glibc aarch64 (Raspberry Pi 3+ / 4 / 5 / Zero 2W, 64-bit OS) |
| `luadch-v3.1.9-windows-x86_64.zip`   | Windows x86_64 (MinGW UCRT64) |
| `ghcr.io/luadch-ng/luadch:v3.1.9`    | Container, linux/amd64 + linux/arm64 |

## Migration from v3.1.8

Drop the new install tree in place of the old one (or `git pull && cmake --build build && cmake --install build` from source). Container users get the bundled `*.lua` sync on the next `docker compose up -d` after `pull`.

No `cfg/cfg.tbl` migration is needed.

## Build from source

```sh
git clone --branch v3.1.9 https://github.com/luadch-ng/luadch.git
cd luadch
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
cmake --install build
```
