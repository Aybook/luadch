# Interlude - Upstream Issue Triage

> Working agreement: see [`CLAUDE.md`](../../CLAUDE.md) §1.
> Upstream policy: see [`CLAUDE.md`](../../CLAUDE.md) §6.

**Status:** complete
**Started:** 2026-05-03
**Closed:** 2026-05-03
**Goal:** Pick off small, clear bug fixes from the 47 open upstream
issues at `luadch/luadch` while we have momentum, and audit a handful
of suspected bugs to confirm whether the Lua-5.4 / OpenSSL-3.x
modernisation closed them implicitly.

This is a one-off detour between Phase 5 (CMake migration) and
Phase 6 (refactor & tests). Not part of the modernisation roadmap;
no review-gate of its own. Documented here so future triage rounds
do not re-discover the same audit results.

---

## 1. Triage filter

Only items matching all of the following were considered:

- Small and clearly fixable in a single PR (one script, < 50-line diff).
- Affects the current 5.4 / OpenSSL-3.x build, or could plausibly do so.
- Is a bug, not a feature request (features are Phase 7+ scope).
- Does not require a real-client environment to investigate (DSCH
  warnings, search-spam reports, AirDC++ NFO bugs were excluded).

This filter excluded ~25 of the 47 upstream issues outright (features
like IPv6 listening, search protection, IP-range bans, web admin) and
~10 more as "needs Phase 6 anyway" (cfg.lua / hub.lua errors that
will be touched when those modules are decomposed).

---

## 2. Outcome

### 2a. Bugs fixed

| Upstream | Our issue | PR | Subject | One-line summary |
|----------|-----------|----|---------| ----- |
| [luadch#227](https://github.com/luadch/luadch/issues/227) | [#22](https://github.com/Aybook/luadch/issues/22) | [#23](https://github.com/Aybook/luadch/pull/23) | `cmd_delreg` help-text fallback | "delregs a new user" -> "an existing user" |
| [luadch#234](https://github.com/luadch/luadch/issues/234) | [#24](https://github.com/Aybook/luadch/issues/24) | [#25](https://github.com/Aybook/luadch/pull/25) | `cmd_usercleaner` showghosts crash | guard `reg_date` before `>= expired_days` |
| [luadch#199](https://github.com/luadch/luadch/issues/199) | [#26](https://github.com/Aybook/luadch/issues/26) | [#27](https://github.com/Aybook/luadch/pull/27) | `usr_uptime` first-login crash | drop `else` so entry-setup runs after nil-init |
| [luadch#195](https://github.com/luadch/luadch/issues/195) | [#28](https://github.com/Aybook/luadch/issues/28) | [#29](https://github.com/Aybook/luadch/pull/29) | `+delreg` reason not relayed | new `msg_del_reason` template (en/de + script) |
| (local) | [#30](https://github.com/Aybook/luadch/issues/30) | [#31](https://github.com/Aybook/luadch/pull/31) | `make_cert.bat` on OpenSSL 3.5+ | reorder `openssl rand -hex -out X 16` |
| [luadch#242](https://github.com/luadch/luadch/issues/242) | [#32](https://github.com/Aybook/luadch/issues/32) | [#33](https://github.com/Aybook/luadch/pull/33) | shutdown / restart still allow typing | `onBroadcast` listener swallows during countdown |

The make_cert.bat fix was a local discovery (not from upstream): when
Aybo went to generate certs with the current Git-for-Windows OpenSSL
3.5.6, the script failed because OpenSSL 3.5+ tightened argument
parsing (positional `<num>` must follow all options). Same defect
exists upstream but per CLAUDE.md §6 we do not push back.

### 2b. Audited as non-reproducible on our build

Three upstream bugs were verified as already fixed by our 5.4 /
OpenSSL-3.x / CMake modernisation work. No code change needed; no
issue opened in our tracker. Recorded here so they are not picked
up again at the next triage round.

| Upstream | Subject | How we verified |
|----------|---------|-----------------|
| [luadch#198](https://github.com/luadch/luadch/issues/198) | `etc_keyprint.lua` does not autogenerate keyprint with OpenSSL 3.x | Aybo logged into a TLS-enabled hub on 5.4 + OpenSSL 3.5.6; `+hubinfo` shows `Use Keyprint: YES` and a valid 52-character base32 SHA256 hash. The reporter's symptom is gone. |
| [luadch#236](https://github.com/luadch/luadch/issues/236) | `core/hub.lua: bad argument #3 to 'utf_format' (number expected, got string)` on first login | Login completes cleanly on 5.4 with the canonical welcome message rendered as a string ("This server is running Luadch v2.24 [RC4] [TLS: v1.3] (Uptime: ...)"). The format string in our tree expects 3x `%s` + 4x `%d` and matches the call exactly; upstream reporter likely had a modified lang file with a `%d` at the TLS slot. |
| [luadch#184](https://github.com/luadch/luadch/issues/184) | `cmd_restart` countdown shows duplicated / glitched ASCII digits after `+reload` | Aybo ran `+shutdown` after `+reload` on the live hub; countdown rendered cleanly 9 -> 8 -> 7 -> 6 -> 5 -> 4 -> 3 -> 2 -> 1 -> 0, each digit shown exactly once for 1 second. The Phase-3 listener-cleanup behaviour in `core/scripts.lua` (full `_listeners = {}` wipe on `restartscripts()`) prevents the listener leakage that would have caused duplicates on the old 5.1 build. |

### 2c. Deliberately deferred

- [luadch#237](https://github.com/luadch/luadch/issues/237)
  `cfg.lua:3521 wrong type` - touches the cfg.lua decomposition planned
  for Phase 6; defer until then so the fix lands inside the broader
  refactor.
- [luadch#238](https://github.com/luadch/luadch/issues/238)
  `hub.lua:1578 client_write nil` - same reasoning, this is in the
  hub.lua hot path being untangled in Phase 6.
- [luadch#96](https://github.com/luadch/luadch/issues/96)
  "remove unused variables" - covered by Phase 6's TODO/FIXME cleanup.

---

## 3. Notable findings

### 5.4 / OpenSSL-3.x silently fixed at least three bugs

Three of the audited issues (#198, #236, #184) turned out to be
pre-existing 5.1-era defects that the modernisation work in Phases 2-5
fixed as a side effect. Worth noting because future triage rounds
should keep auditing as a first step before committing to a fix - the
modernisation cycle is still echoing through the bug surface.

### Upstream activity is uneven but reports are usable

The 47 upstream issues span 2015 - 2026. Recent reports (from 2024-2026)
were the most actionable; older ones often pre-dated significant
refactors and the symptoms could not be reproduced cleanly. Triage
should prefer recent reports going forward.

### Pattern fixes go in pairs

`cmd_shutdown.lua` and `cmd_restart.lua` shared the typing-during-
countdown defect identically. Per CLAUDE.md §1.1 (no divergent code
paths) both got the same fix in one PR. The same will apply when we
hit `cmd_ban` / `cmd_unban`, `etc_chatlog` / `etc_motd`, etc. in
Phase 6 - look for sibling files.

---

## 4. What is next

Master is at the merged interlude state. Phase 6 (refactor & tests)
can begin per CLAUDE.md §5.

A release tag covering Phases 1 - 5 plus this interlude is in scope
before Phase 6 starts so that anyone deploying gets a clean version
boundary between "pre-modernisation" and "modernised foundation".
