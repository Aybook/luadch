# Luadch v3.1.6

Security-themed patch release. Hub now defaults to TLS-only with an auto-generated self-signed cert on first boot, password leakage in admin reply paths is closed for `+setpass` / `+accinfo` / `+usersearch`, and Docker deployments pick up new bundled language files automatically.

## ⚠️ Before upgrading

Back up your `cfg/`, `scripts/lang/`, `scripts/data/`, `scripts/cfg/`, `certs/`, and `secrets/` directories. This release touches lang files in particular - if you have customised translations for `cmd_accinfo`, `cmd_setpass`, or `cmd_usersearch`, see the **Lang file changes** section below before letting the autosync run.

```sh
tar -czf "luadch-backup-$(date +%F).tar.gz" cfg scripts certs secrets
```

## Lang file changes

This release adds new lang keys and one renamed value. Operators with stock bundled lang files (`scripts/lang/<plugin>.lang.{en,de}`) get all of this automatically via the Docker autosync introduced in [#118](https://github.com/luadch-ng/luadch/pull/118), or via `cmake --install build` for source builds. Operators with **custom** lang files have a small one-time merge:

| Plugin | What changed |
|---|---|
| `cmd_accinfo.lang.{en,de}` | New key: `msg_redacted = "<REDACTED>"`. Falls back to the hardcoded English default if missing. |
| `cmd_usersearch.lang.{en,de}` | Same new key: `msg_redacted = "<REDACTED>"`. |
| `cmd_setpass.lang.{en,de}` | Existing `msg_ok` rewritten: `"Password was changed to: "` -> `"Password was changed."` (no longer concatenates the password value). Custom translations that read like a sentence-prefix will sit next to a missing value cosmetically; behaviour is correct regardless. |
| `usr_nick_length.lang.{en,de}` | New file - previously the script had no lang infrastructure. Two keys: `msg_failedauth_reason`, `msg_invalid_length`. |

## Breaking

- **TLS-only default** ([#77](https://github.com/luadch-ng/luadch/issues/77) / [#113](https://github.com/luadch-ng/luadch/pull/113)) - the bundled `cfg/cfg.tbl` now ships TLS-only on **both stacks**: IPv4 (`tcp_ports = { }`, `ssl_ports = { 5001 }`) and IPv6 (`tcp_ports_ipv6 = { }`, `ssl_ports_ipv6 = { 5003 }`), with `use_ssl = true`. Existing `cfg/cfg.tbl` files are **not migrated** - operators upgrading keep their plain-port settings on both stacks until they choose to flip. Fresh installs and Docker first-boot are TLS-only by default.

## Features

- **Auto-generated self-signed cert on first boot** ([#113](https://github.com/luadch-ng/luadch/pull/113)) - if `certs/servercert.pem` / `serverkey.pem` are missing, the hub generates a P-256 ECDSA pair via adclib's OpenSSL bindings and writes them to disk before the TLS listener binds. Keyprint logged to stdout in the boot banner so `docker compose logs` / the launching terminal shows the `adcs://host:port/?kp=SHA256/<base32>` URL to share with users. `make_cert.{sh,bat}` stay around for manual rotation; the entrypoint no longer runs them.
- **Slaxml XML parser bundled** ([#112](https://github.com/luadch-ng/luadch/pull/112)) - `lib/slaxml/slaxml.lua` is now part of the install tree. Plugins can `use "slaxml"` for RSS / XML feed parsing without a separate dep install.
- **Docker autosync extended to lang files** ([#118](https://github.com/luadch-ng/luadch/pull/118)) - new bundled `scripts/lang/*.lang.*` files land on operator mounts automatically. Strictly add-only, existing translations are never overwritten. The same `LUADCH_AUTOSYNC_SCRIPTS=0` opt-out covers both the `*.lua` overwrite-on-diff sync and the new lang add-only sync.

## Bugfixes

- **Password redaction in admin reply paths** ([#95](https://github.com/luadch-ng/luadch/issues/95) partial / [#119](https://github.com/luadch-ng/luadch/pull/119)):
  - `+setpass` drops the password from the **caller's** reply. The target user still receives the new password via PM (admin-sets-target case) - they need it to log in.
  - `+accinfo` and `+usersearch` show `<REDACTED>` in the password column instead of the cleartext value.
  - `+reg` auto-generated password delivery is **intentionally unchanged** - target needs the value to log in. The `cmd_reg` redesign is Phase-8+ scope and depends on either an alternate delivery channel ([#100](https://github.com/luadch-ng/luadch/issues/100) SMTP) or a token-based first-login flow.
- **`usr_nick_length` localisation** ([#48](https://github.com/luadch-ng/luadch/issues/48) i18n half / [#117](https://github.com/luadch-ng/luadch/pull/117)) - operator-facing `onFailedAuth` reason and user-facing `ISTA 221` kill message now route through the new `scripts/lang/usr_nick_length.lang.{en,de}`.
- **Plugin-header grammar fix** ([#114](https://github.com/luadch-ng/luadch/issues/114) / [#116](https://github.com/luadch-ng/luadch/pull/116)) - `'an user'` -> `'a user'` across nine bundled plugin headers. Comment-only.

## Notes

- Bug-report and feature-request issue templates added under `.github/ISSUE_TEMPLATE/`.
- Smoke harness: 14/14 PASS on Linux + Windows (no test count change in this release; existing tests cover the new behaviour).

## Downloads

| File | Platform |
|---|---|
| `luadch-v3.1.6-linux-x86_64.tar.gz` | Linux glibc x86_64 |
| `luadch-v3.1.6-windows-x86_64.zip`  | Windows x86_64 (MinGW UCRT64) |
| `ghcr.io/luadch-ng/luadch:v3.1.6`   | Container, linux/amd64 + linux/arm64 |

## Migration from v3.1.5

Drop the new install tree in place of the old one (or `git pull && cmake --build build && cmake --install build` from source). Container users get both the bundled `*.lua` sync and the new lang add-only sync on the next `docker compose up -d` after `pull`.

If you want to flip to TLS-only on an existing deployment, edit `cfg/cfg.tbl`. luadch separates IPv4 and IPv6 listeners into distinct port arrays - flip both stacks to mirror the new bundled defaults:

```lua
tcp_ports      = { },
ssl_ports      = { 5001 },
tcp_ports_ipv6 = { },
ssl_ports_ipv6 = { 5003 },
use_ssl        = true,
```

If you only run on one stack, leave the other one as-is. Then `+reload` (or restart the container). The hub's auto-cert-gen path picks up the missing `certs/serverkey.pem` / `servercert.pem` and writes a fresh self-signed pair before binding the listener.

## Build from source

```sh
git clone --branch v3.1.6 https://github.com/luadch-ng/luadch.git
cd luadch
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
cmake --install build
```
