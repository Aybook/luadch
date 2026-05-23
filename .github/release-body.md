# Luadch v3.1.10

**Maintenance patch release** on the `release/3.1.x` line. Two security / UX bugfixes cherry-picked from master. No breaking changes; no cfg / lang-file changes; drop-in upgrade from v3.1.9.

## ⚠️ Before upgrading

Back up your `cfg/`, `scripts/lang/`, `scripts/data/`, `scripts/cfg/`, `certs/`, and `secrets/` directories before any upgrade, on principle. **This release has no required cfg or lang-file changes** - the upgrade is a pure binary / script tree swap, but the backup discipline is worth keeping.

```sh
tar -czf "luadch-backup-$(date +%F).tar.gz" cfg scripts certs secrets
```

## Why upgrade

**If operators have set `kill_wrong_ips = false`** (NAT-weird deployments) - their hub was forwarding unverified primary-IP claims to other clients, opening the historical [DC++ DDoS-amplification vector](https://en.wikipedia.org/wiki/Direct_Connect_(protocol)#Direct_Connect_used_for_DDoS_attacks). This release closes that path.

**If operators see FAILED-AUTH spam** with reason `"User sent offending flag in INF: I4"` (HadesDCH reported this) - legitimate DC++ clients refreshing INF after NAT events were being killed in a loop. This release stops the kill and silent-strips the field instead.

Default-config hubs (`kill_wrong_ips = true`, no INF-refresh storms) are not actively affected by either bug, but the upgrade is harmless and recommended.

## Bugfixes

### [#214](https://github.com/luadch-ng/luadch/issues/214) Gap 2 - DDoS-amplification on `kill_wrong_ips = false` opt-out

`core/hub_dispatch.lua` `elseif infip_match ~= userip` branch: when `kill_wrong_ips = false` AND the BINF claim doesn't match the TCP-source IP, the wrong claim STAYED in `adccmd` and was broadcast to other clients - they would then direct CTM / RCM frames at the spoofed address (Maksis-confirmed DC++ DDoS-amp vector).

**Fix:** the opt-out path now stamps the authenticated `userip` over the lie via `adccmd:setnp(userfam, userip)`. Opt-out intent (don't kill the user) preserved. Default `kill_wrong_ips = true` deployments unaffected. Side benefit: legitimate NAT-deployments now broadcast a routable IP, so other clients' CTMs succeed (pre-fix they targeted the wrong IP and failed).

The companion Gap 1 (secondary-family unverified broadcast) is the upcoming HBRI implementation's responsibility - tracked on master.

### [#222](https://github.com/luadch-ng/luadch/issues/222) (HadesDCH) - post-login INF with `I4` / `I6` killed legitimate users

`scripts/hub_inf_manager.lua` `forbidden.flags_on_inf` contained `I4` / `I6` (originally added in #97 to prevent post-login IP-spoofing). Real DC++ clients refresh INF including `I4` on routine triggers (NAT rebind, ISP-IP change, plain refresh); pre-fix those legitimate refreshes triggered `ISTA 240` + `TL300` reconnect-block, producing FAILED-AUTH log spam and bouncing users in a loop.

**Fix:** `flags_on_inf` split into `_kill` (`PD` / `ID` - identity spoofing, real attack signal = kill) and `_strip` (`I4` / `I6` - IP mutation attempt OR routine refresh = silent-strip). The strip path removes `I4` / `I6` from `cmd` via `cmd:deletenp()` before applying remaining fields. Anti-spoofing intent of #97 preserved: stored `_inf` IP is never mutated, broadcast doesn't carry the new claim. Other INF fields in the same update (DE, SS, etc.) still get applied normally. Plugin v0.06 → v0.07.

## Build / runtime

No changes. Same Lua 5.4.7, same LuaSec 1.3.2, same LuaSocket 3.1.0, same build toolchain as v3.1.9.

The `linux-aarch64` artifact is built with the Bullseye-container pipeline introduced as the v3.1.9 in-place asset swap (glibc 2.31 baseline, works on Pi OS Bullseye / Bookworm / DietPi v9.x).

## Upgrade

```sh
# Linux x86_64 / aarch64
wget https://github.com/luadch-ng/luadch/releases/download/v3.1.10/luadch-v3.1.10-linux-x86_64.tar.gz
tar xzf luadch-v3.1.10-linux-x86_64.tar.gz
# move your cfg/, scripts/data/, etc into the new tree, restart hub

# Windows
# Download luadch-v3.1.10-windows-x86_64.zip, extract, copy cfg+data over, restart.
```

3.2.x is the active development line on `master`; security backports continue to land on `release/3.1.x` per [`CLAUDE.md` §8](https://github.com/luadch-ng/luadch/blob/master/CLAUDE.md#8-release-lines-and-support-policy).
