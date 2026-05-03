# Phase 4 — Dependency audit

> Working agreement: see [`CLAUDE.md`](../../CLAUDE.md) §1.
> Roadmap: see [`CLAUDE.md`](../../CLAUDE.md) §5.

**Status:** complete
**Started:** 2026-05-03
**Closed:** 2026-05-03
**Goal as originally planned:** Bump bundled `basexx`, `LuaSocket`,
`LuaSec` to current upstream where compatible with the now-current
Lua 5.4 runtime.

**Outcome:** Phase 4 closed as **audit-only**. We are already on the
latest tagged upstream version of every bundled dependency that has
one. There is nothing meaningful to bump.

---

## 1. Findings

| Lib       | Bundled         | Latest upstream tag | HEAD vs tag             | Bump value |
|-----------|-----------------|---------------------|-------------------------|------------|
| basexx    | unmarked        | v0.4.1 (2019)       | +3 commits, all rockspec metadata | none |
| LuaSocket | 3.1.0           | v3.1.0 (2022)       | +48 commits since 2022, all cleanup / docs / repo migration | none |
| LuaSec    | 1.3.2           | v1.3.2 (2023)       | +2 commits in July 2025 | see §1.1 |
| adclib    | in-tree, no upstream | — | — | n/a |
| slnunicode| replaced by Lua shim in Phase 3 (commit `f19cbe4`) | n/a | — | already done |

### 1.1 The two LuaSec post-tag commits

```
2025-07-10  Fix: use luaL_register instead of luaL_openlib
2025-07-10  Add compatibility flat to OpenSSL 1.1.1 version
```

Neither of these commits addresses the OpenSSL-3.0 deprecation
warnings tracked in issue #3. The first reverts a 5.2-style API call
back to a 5.1-style one (counter-productive for our Lua 5.4 build);
the second is backwards compatibility for the older OpenSSL 1.1.1
line. Pulling them gives no benefit and introduces risk.

---

## 2. Issue #3 — OpenSSL 3.0 deprecation warnings

The Linux build emits 5 deprecation warnings from the bundled `luasec/`
C sources against system OpenSSL 3.x. The decision after this audit:
**accept and document, do not "fix" by switching libraries.**

### 2.1 Why a library swap is not warranted

- **The deprecation is cosmetic, not functional.** OpenSSL marks
  functions deprecated long before removing them. The functions LuaSec
  uses (`EC_KEY_*`, `DH_free`, `SSL_CTX_set_tmp_dh_callback`,
  `PEM_read_bio_DHparams`) are deprecated since OpenSSL 3.0 (2021),
  still present in the current 3.x line, and OpenSSL has historically
  taken multiple major versions before actually removing things —
  ABI stability is core to their contract.
- **Crypto strength lives in OpenSSL, not LuaSec.** LuaSec is a thin
  binding layer; the actual handshake and cipher selection happen in
  OpenSSL itself. We negotiate TLS 1.3 with `TLS_AES_256_GCM_SHA384`
  out of the box. Replacing LuaSec with another binding (e.g.
  lua-openssl) does not improve user-visible TLS posture.
- **No drop-in alternative exists.** A real swap means rewriting all
  TLS code in `core/server.lua` (989 lines built around the
  LuaSocket+LuaSec pattern), plus likely the LuaSocket layer too,
  plus a glue layer. Network-stack-renewal scope, not modernisation
  scope.
- **Working Agreement §1.6** — no drive-by refactors. We don't
  manufacture multi-week network-stack rewrites for cosmetic warnings.

### 2.2 Decision

Issue #3 reclassified as `upstream-blocked` + `wontfix`. Re-evaluation
trigger: either OpenSSL announces a concrete removal date for the
deprecated APIs, or LuaSec upstream lands an EVP / provider migration.
A note pointing at this rationale was added to
[`docs/BUILDING.md`](../BUILDING.md#known-cosmetic-build-warnings).

---

## 3. What changed in this phase

- `docs/phases/PHASE_4.md` — this report.
- `docs/BUILDING.md` — new "Known cosmetic build warnings" section
  pointing readers at issue #3.
- Issue #3 labels updated: `phase-4` removed; `upstream-blocked` and
  `wontfix` added. Label `upstream-blocked` itself created.

No source code touched. No bundled deps touched.

---

## 4. Phase 4 review-gate checklist

- [x] Audit done: confirmed all bundled deps are at or beyond their
      latest meaningful upstream tag
- [x] Issue #3 reclassified with rationale documented
- [x] Build-output behaviour confirmed unchanged (we did not touch
      anything that would affect the binary)
- [x] BUILDING.md updated so future contributors see the warning
      explanation up front
- [x] Phase journal written

Phase 4 is closed. Phase 5 (CMake migration) may begin.
