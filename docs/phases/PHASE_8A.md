# Phase 8a-1 - ADC input validation audit findings

> Working agreement: see [`CLAUDE.md`](../../CLAUDE.md) §1.
> Phase scope: see [`CLAUDE.md`](../../CLAUDE.md) §5 ("Phase 8+ - Future features (post-modernisation)").
> Tracker: [issue #121](https://github.com/luadch-ng/luadch/issues/121).

**Status:** read-only audit pass complete (first iteration)
**Started:** 2026-05-10
**Scope:** ADC input-validation surfaces across the modernised
luadch core, the bundled `scripts/`, and the companion plugin
repository [`luadch-ng/scripts`](https://github.com/luadch-ng/scripts).
No code changed in 8a-1. Each finding is filed as a GitHub issue
(or a sub-section here) and triaged into a later sub-phase
(8a-2..N) by severity.

The Phase 8a programme is the natural follow-on from Phase 7
(security audit + hardening, complete 2026-05-04). Phase 7 closed
the structural / connection-level / file-load layer; Phase 8a
covers what's left: per-field semantic validation in the
post-parse handlers and a regression net for malformed ADC input.

---

## 1. Methodology

External proposal from a luadch user (no GitHub handle) suggested a
focused audit of all externally-controlled ADC input fields with a
checklist of edge-case classes per field. Filed as
[issue #121](https://github.com/luadch-ng/luadch/issues/121). The
audit splits into three sub-phases:

- **8a-1** (this doc): read-only pass; document current behaviour
  per field for each edge-case class; file findings as issues.
- **8a-2** ([PR #123](https://github.com/luadch-ng/luadch/pull/123)):
  negative-test fuzz suite added to `tests/smoke/run.py` (14 -> 30
  tests). Caught five real bugs on first run, fixed them inline:
  - `core/adc.lua` parse() positional-param nil-safety
  - bundled scripts `usr_share`, `usr_slots`, `etc_records`,
    `cmd_hubinfo`, `cmd_hubstats`, `cmd_slots`, `etc_trafficmanager`:
    `(user:share() or 0)` / `(user:slots() or 0)` defensive coercion
- **8a-3..N**: per-finding fix waves. One PR per cluster.

This document records the 8a-1 audit pass.

### Threat model

Same as Phase 7 (see
[`PHASE_7_FINDINGS.md`](PHASE_7_FINDINGS.md) §1). The ADC client
on the public internet is untrusted; the hub must remain available
and not crash on any input the client can send. Plugin scripts in
`scripts/` are admin-authored and trusted. The companion
[`luadch-ng/scripts`](https://github.com/luadch-ng/scripts) repo is
operator-installed; same trust contract as bundled scripts when
deployed.

### Severity scale

| Tag | Meaning |
|---|---|
| **critical** | RCE without prior privilege, or trivially exploitable on a default install |
| **high** | RCE with limited prior privilege, auth bypass, or stable DoS against a default install |
| **medium** | Account-DoS, partial info disclosure, or exploit conditional on a non-default config |
| **low** | Defence-in-depth gap, or exploit requires improbable preconditions |
| **info** | No exploit; documents an assumption / portability landmine / hygiene item |

### Severity rollup (this audit pass)

| Severity | Count | Status |
|---|---|---|
| critical | 0 | - |
| high | 0 | - |
| medium | 1 | fixed in [PR #123](https://github.com/luadch-ng/luadch/pull/123) (8a-2) |
| low | 5 | 1 in luadch unfixed, 4 in luadch-ng/scripts unfixed |
| info | 2 | - |

The fuzz suite in [PR #123](https://github.com/luadch-ng/luadch/pull/123)
already covers the `medium` finding (parse positional nil) plus the
seven sites of `(user:share/slots() or 0)` defensive coercion in
bundled scripts. The remaining `low` items are listed here for
follow-up fix-PRs.

---

## 2. Findings

### Medium

#### F-PRS-7: parse() crashes on malformed positional params (FIXED)

- **Location:** [`core/adc.lua:849-861`](../../core/adc.lua#L849-L861) (post-fix; pre-fix was the same site)
- **Status:** Fixed in [PR #123](https://github.com/luadch-ng/luadch/pull/123).
- **Symptom:** A malformed ADC command with fewer positional parameters than the cmd descriptor declared (e.g. `BMSG <sid>` with no body) left `buffer[i] == nil`. The parse loop passed nil straight into the type-validator, which crashed on `string_find(nil, "%c")` from the `default` validator.
- **Exploit vector:** Post-login, any client could send `BMSG <sid>\n` (or another command short of one positional param) and force a Lua error in the parser. Connection got dropped per the parse-failure path; no script-level RCE; effectively a degraded-functionality DoS against a single connection per crash. Hub-wide impact bounded by Phase 7d's reentrant-parse fix (#65) - parse-locals are per-call so one crash does not corrupt other parses.
- **Severity:** medium. Requires an authenticated client (post-login) but no special privilege; reproducible with a one-line ADC frame.
- **Fix:** Reject nil positional params the same way an invalid value would be. Returns parse failure + `out_put` log entry.

### Low

#### F-INF-1: bundled and companion plugins crash on missing optional INF fields (PARTIALLY FIXED)

ADC `INF` fields like `SS` (share size), `SF` (shared files), `SL` (slots), `DS` / `US` (download / upload speed), `DE` (description), `EM` (email), `VE` (version), and the `HN` / `HR` / `HO` triplet (hubs as user / regged / op) are *optional* per the ADC spec - a conformant client may send a BINF that omits any of them. The hub stores the absence as `nil` on the user object; `user:share()` etc. return nil for the missing field.

Plugin code that reads these getters into arithmetic / comparisons / string operations without a nil guard crashes the listener on every login from such a client. Pre-fuzz-suite, this happened silently on every smoke run because `test_no_script_errors` only scanned hub stdout, not `log/error.log` (separate finding F-AUD-1 below).

##### F-INF-1a: bundled scripts (FIXED)

| File | Line | Pattern | Field | Fix in PR #123 |
|---|---|---|---|---|
| [`scripts/usr_share.lua`](../../scripts/usr_share.lua#L73) | 73 | `if user_share > max` after bare `user:share()` | SS | `(user:share() or 0)` |
| [`scripts/usr_slots.lua`](../../scripts/usr_slots.lua#L61) | 61 | `if user_slots < min` after bare `user:slots()` | SL | `(user:slots() or 0)` |
| [`scripts/etc_records.lua`](../../scripts/etc_records.lua#L247) | 247 | `new_hubshare + user:share()` | SS | `(user:share() or 0)` |
| [`scripts/etc_records.lua`](../../scripts/etc_records.lua#L293) | 293 | `target_usershare > tonumber(records[8])` | SS | `(user:share() or 0)` |
| [`scripts/cmd_hubinfo.lua`](../../scripts/cmd_hubinfo.lua#L403) | 403 | `hshare = hshare + ushare` after bare `user:share()` | SS | `(user:share() or 0)` |
| [`scripts/cmd_hubstats.lua`](../../scripts/cmd_hubstats.lua#L128) | 128 | `hshare + user:share()` direct | SS | `(user:share() or 0)` |
| [`scripts/cmd_slots.lua`](../../scripts/cmd_slots.lua#L65) | 65 | `if slots > 0` after bare `user:slots()` | SL | `(user:slots() or 0)` |
| [`scripts/etc_trafficmanager.lua`](../../scripts/etc_trafficmanager.lua#L353) | 353-357 | `if target:share() == 0 / < min` | SS | local `share = target:share() or 0` |

##### F-INF-1b: bundled `usr_hubs.lua` arithmetic-before-nil-check (UNFIXED)

- **Location:** [`scripts/usr_hubs.lua:119-122`](../../scripts/usr_hubs.lua#L119-L122)
- **Status:** Unfixed. Filed as 8a-3 fix candidate.
- **Symptom:**
  ```lua
  local hn, hr, ho = user:hubs()
  local hm = hn + hr + ho             -- crashes if any of hn/hr/ho is nil
  if not ( hn and hr and ho ) then    -- nil-check happens AFTER the crash
      user:kill( ... )
      return PROCESSED
  ```
  A client BINF without the `HN` / `HR` / `HO` triplet returns nil from `user:hubs()`. The arithmetic on line 120 fires before the nil-check on line 121.
- **Exploit:** Any client can send BINF without HN/HR/HO. Listener crashes on every such login.
- **Severity:** low. Localised to one plugin's onConnect; per-connection failure; hub stays up.
- **Recommended fix:** swap the nil-check before the arithmetic, or use `(... or 0)` coercion on each component.

##### F-INF-1c: bundled scripts using `user:description()` in `utf.sub` without nil-check (UNFIXED)

- **Location:**
  - [`scripts/usr_desc_prefix.lua:71`](../../scripts/usr_desc_prefix.lua#L71): `local desc = utf.sub( user:description(), utf.len( prefix ) + 1, -1 )`
  - [`scripts/etc_trafficmanager.lua:650`](../../scripts/etc_trafficmanager.lua#L650): same pattern with `target:description()`
- **Status:** Unfixed. Filed as 8a-3 fix candidate.
- **Symptom:** `user:description()` is nil if the client did not send `DE` in BINF. `utf.sub(nil, ...)` raises.
- **Exploit:** Any client can omit DE. Listener crashes on every onInf or other event that reaches these branches.
- **Severity:** low. Plugin-local, hub stays up.
- **Recommended fix:** `local desc = user:description() or ""` before the `utf.sub`. Other call sites in `etc_trafficmanager.lua` (lines 425, 432, 439, 443, 464, 471) already use this pattern; the missing two are the divergent ones.

##### F-INF-1d: companion `luadch-ng/scripts` scripts unguarded (UNFIXED)

- **Location (companion repo):**
  - [`scripts/etc_maxhubs_announcer/etc_maxhubs_announcer.lua:85-86`](https://github.com/luadch-ng/scripts/blob/master/scripts/etc_maxhubs_announcer/etc_maxhubs_announcer.lua#L85-L86): `local hubs = hn + hr + ho` on bare `user:hubs()` - same pattern as F-INF-1b above
  - [`scripts/etc_openhubs_announcer/etc_openhubs_announcer.lua:81-89`](https://github.com/luadch-ng/scripts/blob/master/scripts/etc_openhubs_announcer/etc_openhubs_announcer.lua#L81-L89): partially guards `hn` (`local open = hn or "unbekannt"`) but then compares `open > 0` which crashes if `open == "unbekannt"`
  - [`scripts/ptx_tagcheck/ptx_tagcheck.lua:171`](https://github.com/luadch-ng/scripts/blob/master/scripts/ptx_tagcheck/ptx_tagcheck.lua#L171): bare `user:slots(), user:hubs()` multi-return into local variables used downstream
  - [`scripts/etc_clientblocker/etc_clientblocker.lua:68`](https://github.com/luadch-ng/scripts/blob/master/scripts/etc_clientblocker/etc_clientblocker.lua#L68): `hub_escapefrom( user:version() )` - `hub.escapefrom(nil)` may or may not crash depending on the C binding; merits a check
- **Status:** Unfixed. Filed as 8a-3 fix candidate in the companion repo.
- **Severity:** low. Same shape as F-INF-1a/b/c.
- **Recommended fix:** same `(... or 0)` / `(... or "")` coercion pattern.

#### F-AUD-1: smoke harness only scanned hub stdout, missing all error.log traffic (FIXED)

- **Location:** [`tests/smoke/run.py`](../../tests/smoke/run.py) `test_no_script_errors`
- **Status:** Fixed in [PR #123](https://github.com/luadch-ng/luadch/pull/123).
- **Symptom:** The function read from `staging_dir / "log" / "smoke-hub.log"` (the captured Popen stdout) and grepped for `"script error:"`. Lua-side `out.error()` writes to `log/error.log` on disk, not stdout. Pre-fix, every plugin error from F-INF-1 hits was silently produced on every clean smoke run; the test passed regardless.
- **Severity:** low (audit / test infrastructure gap). Without the fix, the negative-test fuzz suite would land green in CI even when triggering plugin crashes.
- **Fix:** Test now scans both `smoke-hub.log` (stdout) and `log/error.log`.

### Info

#### F-INF-2: ADC `INF` field-level numeric range checks not enforced

- **Status:** by design (current behaviour), tracked for 8a-3 design decision.
- **Observation:** The ADC parser validates field *syntax* (e.g. `integer = function( str ) return str == "" or string_match( str, "^%-?%d+$" ) end` at [`core/adc.lua:186-189`](../../core/adc.lua#L186-L189)) but NOT *semantic range*. A client can send `SS-1`, `SF999999999999999999`, `SL-100`, etc. and the values are stored on the user object verbatim. Phase 7d (#65) deliberately accepts negative integers because some legacy DC++ clients emit negative `DS` and rejecting them at the parser level was a regression vector (closes upstream `luadch/luadch#241`).
- **Implication:** Any per-field range enforcement (must be >= 0; must be < some plausible upper bound) is the responsibility of post-parse handlers / plugin scripts. The F-INF-1a fixes coerce nil to 0 but do not bound the upper end; a client claiming `SS=999999999999999999` will still be stored at face value. Whether this matters for any specific use case is policy: the hub itself is unaffected, downstream consumers may want bounds.
- **Recommended next step:** decide per-field whether to add a sanity-bound at the post-parse handler (e.g. clamp `SS` to [0, 2^60]), or document the absence as policy. 8a-3 design call.

#### F-INF-3: Phase 8a-1 audit is non-exhaustive

- **Status:** info / scope marker.
- **Observation:** This 8a-1 pass focused on the most obviously suspect call patterns - `user:share()`, `user:slots()`, `user:hubs()`, `user:description()`, `user:version()` consumed in arithmetic / compare / string-op contexts without nil guards. A more exhaustive audit would also walk:
  - Every `cmd:getnp("XX")` consumer in core and bundled scripts; check that nil returns are handled before the value is used.
  - Every `tonumber(...)` site downstream of user-supplied data; check the result is handled when the input was non-numeric.
  - `utf.match` / `string.match` returns inside `local x, y = ...` patterns where the match can fail silently.
- **Recommended next step:** schedule a 8a-1b pass when the 8a-3..N fix waves close. Findings doc updates in place.

---

## 3. Triage table

| ID | Severity | Repo | Status | Tracking |
|---|---|---|---|---|
| F-PRS-7 | medium | luadch | fixed | [PR #123](https://github.com/luadch-ng/luadch/pull/123) |
| F-INF-1a | low | luadch | fixed | [PR #123](https://github.com/luadch-ng/luadch/pull/123) |
| F-INF-1b | low | luadch | open | 8a-3 PR (luadch) |
| F-INF-1c | low | luadch | open | 8a-3 PR (luadch) |
| F-INF-1d | low | luadch-ng/scripts | open | 8a-3 PR (companion) |
| F-AUD-1 | low | luadch | fixed | [PR #123](https://github.com/luadch-ng/luadch/pull/123) |
| F-INF-2 | info | luadch | open / by design | 8a-3 design call |
| F-INF-3 | info | luadch | open / scope marker | 8a-1b future pass |

## 4. Phase 8a closure criteria

- [x] 8a-1 first pass documented (this file).
- [x] 8a-2 fuzz harness landed ([PR #123](https://github.com/luadch-ng/luadch/pull/123)).
- [ ] 8a-3 fix wave: F-INF-1b / F-INF-1c in the luadch repo (one PR).
- [ ] 8a-3 fix wave: F-INF-1d in the companion repo (one PR).
- [ ] 8a-3 design call on F-INF-2 (per-field bounds): decide and either implement or document as policy.
- [ ] 8a-1b second-pass audit when 8a-3 fixes are in: cover `cmd:getnp` consumers, `tonumber` sites, `match` returns.
- [ ] Phase 8a closeout: smoke harness count + this doc updated; phase status flipped to `complete`.
