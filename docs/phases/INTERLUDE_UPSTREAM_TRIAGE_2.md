# Interlude 2 - Upstream Issue Triage

> Working agreement: see [`CLAUDE.md`](../../CLAUDE.md) §1.
> Upstream policy: see [`CLAUDE.md`](../../CLAUDE.md) §6.
> Predecessor: [`INTERLUDE_UPSTREAM_TRIAGE.md`](INTERLUDE_UPSTREAM_TRIAGE.md).

**Status:** in progress
**Started:** 2026-05-04
**Goal:** Second pass over the still-open `luadch/luadch` upstream
issues now that Phases 6 (refactor + smoke harness) and 7 (security
audit + hardening) have landed, and v3.1.0 is released. The first
interlude (2026-05-03) closed six small bugs and audited three more
as pre-fixed by modernisation; this round picks up items that were
deliberately deferred to Phase 6 plus reports filed since.

Same triage filter as Interlude 1: small, clearly fixable, recent
report, no real-client-environment dependency required.

---

## 1. Audit-pass: items already addressed by Phase 6 / 7

These need no code change. Documented here so they are not
re-discovered at the next triage round.

| Upstream | Subject | Where addressed |
|---|---|---|
| [luadch#214](https://github.com/luadch/luadch/issues/214) | Prevent hammering on failed authentication | Phase 7c F-AUTH-3 (PR #64). New `core/ratelimit.lua` `record_authfail` adds per-IP failed-auth tracking with sticky `_ip_blocks` lockout (default 300 s). Per-account `bad_pass_timeout` from upstream still applies on top. |
| [luadch#221](https://github.com/luadch/luadch/issues/221) | Add search protection | Phase 7c F-RL-2 (PR #64). Per-user search-rate cap on BSCH / FSCH / DSCH; default 1 search per 2 s with burst 3 (cfg-tunable to the upstream-suggested 10 s via `ratelimit_user_search_period = 10`). |
| [luadch#237](https://github.com/luadch/luadch/issues/237) | `cfg.lua:3521 wrong type: table expected, got number` on init | Phase 6c-1 (PR #41) extracted `_defaultsettings` into `core/cfg_defaults.lua`. Original `cfg.lua` 3688 -> 668 lines; line 3521 in the upstream code does not exist anymore. The validator pattern that errored has different surface in the new layout; smoke 10/10 PASS confirms init is clean. Deferred from Interlude 1. |
| [luadch#238](https://github.com/luadch/luadch/issues/238) | `hub.lua:1578: attempt to call upvalue 'client_write' (a nil value)` on `+reg` | Phase 6d-1 (PR #45) extracted `createuser` into `core/hub_user_object.lua`. The `client_write` cache (line 165) is now structured `local client_write = _client.write` directly at user-creation, with an explicit no-op fallback when `_client` is nil during the user's lifetime (line 168). Original line 1578 does not exist; refactor restructured the cache so the upstream nil-call cannot occur the same way. Deferred from Interlude 1. |
| [luadch#236](https://github.com/luadch/luadch/issues/236) | `hub.lua:575 bad argument #3 to 'utf_format' (number expected, got string)` | Already covered by Interlude 1 audit (lang-file `%d` mismatch in upstream reporter's setup); current `_pingsup` / `_normalsup` format strings in `hub.lua:467-480` use `%s` for every positional, so number/string mismatches cannot occur in our build. |
| [luadch#242](https://github.com/luadch/luadch/issues/242) | Shutdown countdown allows users to type | Already fixed by our PR #33 (Interlude 1); `+shutdown` and `+restart` countdowns block main-chat broadcasts. |

---

## 2. Items deliberately not picked up

Per CLAUDE.md §1.3 / §5 these belong to other scopes:

- Feature requests: [#201](https://github.com/luadch/luadch/issues/201)
  topic-to-mainchat, [#210](https://github.com/luadch/luadch/issues/210)
  hub_hostaddress reachability check,
  [#216](https://github.com/luadch/luadch/issues/216) start-screen
  stats, [#148](https://github.com/luadch/luadch/issues/148) IP-range
  ban, [#105](https://github.com/luadch/luadch/issues/105) IPv6
  hybrid - all Phase 8+ scope, tracked indirectly in
  [#48](https://github.com/Aybook/luadch/issues/48).
- Pre-2022 issues without clear repro instructions
  ([#1](https://github.com/luadch/luadch/issues/1),
  [#5](https://github.com/luadch/luadch/issues/5),
  [#32](https://github.com/luadch/luadch/issues/32),
  [#57](https://github.com/luadch/luadch/issues/57)) -
  cost-of-investigation outweighs likely impact.
- Client-side bugs: [#197](https://github.com/luadch/luadch/issues/197)
  AirDC++ NFO error - upstream is the AirDC++ project, not luadch.
- [#96](https://github.com/luadch/luadch/issues/96) "remove unused
  variables" - partially covered by Phase 6e dead-file cleanup; the
  remainder is a stylistic sweep, not a bug.

---

## 3. Bugs picked up in Interlude 2

To be filled in incrementally as each PR lands. Plan:

| Upstream | Subject | Status |
|---|---|---|
| [luadch#228](https://github.com/luadch/luadch/issues/228) | `cmd_delreg.lua` can't delete a blacklisted user | TBD |
| [luadch#240](https://github.com/luadch/luadch/issues/240) | `etc_trafficmanager.lua` - no message sent to user | TBD |
| [luadch#241](https://github.com/luadch/luadch/issues/241) | Invalid (negative) DS in INF prevents login | TBD |
| [luadch#200](https://github.com/luadch/luadch/issues/200) | DSCH cross-user routing leak (security) | TBD |
| [luadch#235](https://github.com/luadch/luadch/issues/235) | `user.tbl.bak` never gets updated | TBD |
| [luadch#189](https://github.com/luadch/luadch/issues/189) | Registered users suddenly lose accounts | TBD |

The first three are small, mechanical script-level fixes. The last
three are larger investigations and will get individual PRs.

---

## 4. What is next

After Interlude 2 closes, the modernisation programme + audit + this
round of upstream-bug fixes will all be released. Next natural step
is **Phase 8+** feature work from
[#48](https://github.com/Aybook/luadch/issues/48): TPM/DPAPI key
wrapping, ADC `HSPW` extension proposal, multi-hash schema, external
HTTP/JSON status API, web-based admin panel, IPv6 hybrid listening,
NAT helpers. Each Phase-8+ item gets its own discrete phase or issue
with its own scope and review gate.
