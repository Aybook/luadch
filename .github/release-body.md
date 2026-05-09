# Luadch v3.1.5

Patch release. Closes upstream `luadch/luadch#189` (registered users disappearing) and adds image-side auto-sync of bundled plugin code on `docker compose pull`.

## ⚠️ Before upgrading

Back up your `cfg/`, `scripts/lang/`, `scripts/data/`, `scripts/cfg/`, `certs/`, and `secrets/` directories. Bundled `scripts/*.lua` are auto-synced from the image; everything else is operator-owned and never touched by an upgrade, but a clean snapshot is the safety net for any production hub.

```sh
tar -czf "luadch-backup-$(date +%F).tar.gz" cfg scripts certs secrets
```

## Bugfixes

- [#108](https://github.com/luadch-ng/luadch/issues/108) / [upstream luadch#189](https://github.com/luadch/luadch/issues/189) - registered users no longer disappear from `user.tbl`. Stale file-scope cache in `cmd_nickchange.lua` + non-atomic `saveusers` were the two root causes; both fixed in [#109](https://github.com/luadch-ng/luadch/pull/109).

## Features

- Docker entrypoint auto-syncs bundled `scripts/*.lua` from the image to the mounted `scripts/` directory on every container start ([#110](https://github.com/luadch-ng/luadch/pull/110)). Operator-owned state untouched. Opt-out: `LUADCH_AUTOSYNC_SCRIPTS=0`. See [`docs/DOCKER.md`](https://github.com/luadch-ng/luadch/blob/v3.1.5/docs/DOCKER.md).

## Notes

- `user.tbl.bak` now refreshed on every successful save (was: only at `+reload`). Operators relying on `.bak` as a stale-rollback should adjust workflows.
- Smoke harness: 12 -> 13 tests.

## Downloads

| File | Platform |
|---|---|
| `luadch-v3.1.5-linux-x86_64.tar.gz` | Linux glibc x86_64 |
| `luadch-v3.1.5-windows-x86_64.zip`  | Windows x86_64 (MinGW UCRT64) |
| `ghcr.io/luadch-ng/luadch:v3.1.5`   | Container, linux/amd64 + linux/arm64 |

## Migration from v3.1.4

None required. Drop the new install tree in place of the old one (or `git pull && cmake --build build && cmake --install build` from source). Container users get the auto-sync of bundled `scripts/*.lua` on the next `docker compose up -d` after `pull`.

## Build from source

```sh
git clone --branch v3.1.5 https://github.com/luadch-ng/luadch.git
cd luadch
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
cmake --install build
```
