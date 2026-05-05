# Interlude 2 - Upstream Issue Triage (rounds 2 + 3)

> Working agreement: see [`CLAUDE.md`](../../CLAUDE.md) §1.
> Upstream policy: see [`CLAUDE.md`](../../CLAUDE.md) §6.
> Predecessor: [`INTERLUDE_UPSTREAM_TRIAGE.md`](INTERLUDE_UPSTREAM_TRIAGE.md).

**Status:** complete
**Started:** 2026-05-04
**Closed:** 2026-05-05
**Note:** what was originally scoped as "round 2" picked up four
fixes plus two audits; we then ran a tighter "round 3" pass through
the remaining filter-passing items in the same PR (see §6).
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

### 3a. Bugs fixed

| Upstream | Subject | One-line summary |
|---|---|---|
| [luadch#228](https://github.com/luadch/luadch/issues/228) | `cmd_delreg.lua` can't delete a blacklisted user | Extend `+delreg nick X` to remove X from the blacklist if X is not registered (anymore); new `blacklist_del()` helper + `msg_deblacklist` lang string |
| [luadch#240](https://github.com/luadch/luadch/issues/240) | `etc_trafficmanager.lua` no message / no [BLOCKED] flag with custom prefix scripts | Resolve target via firstnick iteration instead of computing `prefix + firstnick` and looking up `hub.isnickonline()`. Robust against any nick-prefix scheme. |
| [luadch#241](https://github.com/luadch/luadch/issues/241) | Invalid (negative) DS in INF blocks login | `_regex.integer` now accepts signed decimals (`^%-?%d+$`) so a single buggy field doesn't cause the parser to drop the entire BINF |
| [luadch#200](https://github.com/luadch/luadch/issues/200) | SECURITY: DSCH messages received with wrong target SID | `etc_trafficmanager.lua` `onSearch` listener no longer fans out D / E type searches; lets hub's default direct-routing path deliver to the single intended SID |

### 3b. Audited as already addressed by our fork

| Upstream | Subject | How |
|---|---|---|
| [luadch#235](https://github.com/luadch/luadch/issues/235) | `user.tbl.bak` never gets updated | Our `scripts/cmd_reg.lua` and `scripts/cmd_delreg.lua` already call `cfg.checkusers()` after every `+reg` / `+delreg` (we re-confirmed during this triage), so `user.tbl.bak` refreshes on every admin command in addition to hub start. Operators on hubs with no admin churn AND no restarts can run `+reload` to force a refresh; an automatic periodic refresh would be a small `etc_userdb_backup.lua` script with an `onTimer` handler, deferred as a Phase-8+ feature. **A naive "mirror bak on every saveusers" fix was prototyped and reverted (commit b4781ef): it would worsen #189-class data loss because both files lose a missing entry simultaneously, defeating bak's role as a recovery snapshot.** |

### 3c. Documented without code change

| Upstream | Subject | Disposition |
|---|---|---|
| [luadch#189](https://github.com/luadch/luadch/issues/189) | Registered users suddenly lose their accounts | **Real bug, root cause unclear.** Repro steps in the upstream comment thread (ryehamstrawberry, 2022-08-18; Sopor, 2024-01-23 with concrete `user.tbl` / `user.tbl.bak` diff): `+reg` a new user, have them log in, force-close the connection mid-session before clean logout, wait ~24 h. Account survives in `user.tbl.bak` from the `+reg`-time `checkusers` snapshot; missing from `user.tbl` after some later `saveusers`. Workaround: `+reload`, which re-reads `user.tbl.bak` if `user.tbl` is corrupt or simply hasn't been refreshed via `cfg.checkusers()`. Investigation during this triage: traced `_regusers` mutation paths in `core/hub.lua` (`reguser`, `delreguser`, `loadregusers`, `disconnect`), `core/hub_user_object.lua` (`setlevel` / `setpassword` / `setregnick`), `core/hub_dispatch.lua` (HPAS handler). `_regusers` is updated in place (Lua tables-by-reference) and the bind-late wiring keeps closures pointing at the same table, so a single forgotten entry cannot trivially happen. Best guess: a race between `disconnect` for the previous session and a subsequent `loadregusers` / `updateusers` call (e.g. via `+reload` triggered by another script). Not safe to fix speculatively without a clean repro. |

A latent correctness bug spotted during the #189 investigation but
NOT fixed (and not the cause of #189): in
[`core/hub_user_object.lua:423`](../../core/hub_user_object.lua) the
`setregnick` path stores the user-object in `_regusernicks[nick]`
instead of the profile table that `reguser` and `updateusers` store.
The whole `setregnick` code path is dead in the bundled scripts -
the only direct caller is commented out in `core/hub_dispatch.lua`
and `examples/etc/other_available_scripts/cmd_nick.lua` (the latter
explicitly notes "this doesnt work as expected at the moment").
Filed for a future follow-up if `+nickchange` ever gets revived.

---

## 4. Notable findings

### Backup-file design tension (#235 vs #189)

Mirroring `user.tbl.bak` on every save (the obvious-looking #235 fix)
makes `user.tbl.bak` a worse recovery target: any data-loss bug that
mutates `_regusers` between two saves loses the entry from BOTH files
simultaneously. The original "snapshot at admin-command time"
behaviour is what saved Sopor's data in #189 (bak contained the
missing user). Conclusion: the right model is multiple-snapshot
rotation (e.g. `user.tbl.bak`, `user.tbl.bak.1`, `user.tbl.bak.2`,
trimmed to N), not "always-mirror". Reserved as a Phase-8+ proposal.

### Phase 7's Interlude-1-style gating still useful

Three of the six picked-up issues either had a known repro path with
a small fix (#228, #240, #241) or were a small targeted code change
(#200). The two that didn't (#235, #189) were diagnosed during this
triage and either confirmed-already-handled or documented honestly
without a speculative fix. The triage filter from Interlude 1 holds
up: prefer issues that fit a single-PR diff, recent reports, no
real-client-environment dependency.

---

## 5. What is next

Master is at the merged Interlude-2 state. After the close-out PR
lands, the `phase-7` and upstream-triage rounds are done. Next
natural step is **Phase 8+** feature work from
[#48](https://github.com/Aybook/luadch/issues/48): TPM / DPAPI key
wrapping, ADC `HSPW` extension proposal, multi-hash schema, external
HTTP / JSON status API, web-based admin panel, IPv6 hybrid listening,
NAT helpers, multi-snapshot user-db rotation (per §4 above). Each
Phase-8+ item gets its own discrete phase or issue with its own scope
and review gate.

---

## 6. Round 3 add-on (same PR)

After §1-5 settled, a second sweep through the still-open upstream
issues turned up five more candidates that fit the triage filter.
Bundled into the same PR rather than a fresh interlude.

### 6a. Audited as already addressed by an earlier fix

| Upstream | Subject | Disposition |
|---|---|---|
| [luadch#226](https://github.com/luadch/luadch/issues/226) | AirDC++ 4.21 "Search spam detected (severe)" disconnects users | Same root cause as #200: `etc_trafficmanager.lua` `onSearch` was fanning out D / E direct searches to every user. AirDC++ counts incoming-search frequency to detect "spam"; with the fan-out, every user received searches addressed to others, tripping the threshold. PR commit 1384825 stops the fan-out; expected to also clear the AirDC++ threshold trigger as a side-effect. Audit-only here. |
| [luadch#230](https://github.com/luadch/luadch/issues/230) | Sporadic "Invalid password" auth failures for previously-OK users | Symptom matches #189: when a registered user vanishes from `user.tbl` (per the as-yet-unresolved data-loss bug), their next login fails as "invalid password" because the per-account `profile` lookup is gone. No independent root cause identified. Tracked alongside #189 in §3c above; same workaround (`+reload`). |

### 6b. Fixed in round 3

| Upstream | Subject | One-line summary |
|---|---|---|
| [luadch#223](https://github.com/luadch/luadch/issues/223) | Commands without `[+!#]` prefix leak into main chat | Add an `onBroadcast` fallback in `etc_hubcommands.lua`: if the message starts with a known command name as a whole word and is shaped like a forgotten command (`^cmd$` or `^cmd <args>$`), swallow the broadcast and reply with a prefix hint. |
| [luadch#217](https://github.com/luadch/luadch/issues/217) | `cmd_mass` `+help` shows "Min Level: 20" even when 30/40/50 are denied | `util.getlowestlevel()` returns just the lowest TRUE-keyed level; the help template renders that single number, hiding false-gaps. Append the actual permitted-level list to `help_desc` at script-load time, formatted with level names where available. |
| [luadch#177](https://github.com/luadch/luadch/issues/177) | Cryptic "wrong sslctx parameters: error loading private key ((null))" on first Windows run | `core/server.lua`'s `wrapserver` now `io.open`-pre-checks `sslctx.{key,certificate,cafile}` before calling `ssl_newcontext`, and surfaces a human-readable hint pointing at `certs/make_cert.{sh,bat}` or `use_ssl = false`. |

### 6c. Bookkeeping

The round-3 audits / fixes share the same triage filter, smoke-test
floor, and PR as round 2. Final running tally for both rounds
combined:

- 7 fixes (round 2: #228, #240, #241, #200; round 3: #223, #217, #177)
- 8 audits as already-addressed (round 2: #214, #221, #236, #237, #238, #242; round 3: #226, #230)
- 1 documented-without-fix (#189); #230 cross-referenced

10 / 10 smoke PASS unchanged across all 7 fix commits + 1 revert.
