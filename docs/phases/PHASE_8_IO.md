# Phase 8 - IO layer rework

**Status:** in progress (started 2026-05-15)
**Integration branch:** `phase8-io` (steps land as sub-PRs into this branch;
the branch merges to `master` once the whole phase is reviewed and green).
**Drivers:** #82 (HTTP API), #83 (Prometheus), #147 T2.2 BLOM, #147 T3.2 ZLIF.

## Why

`core/server.lua` delegates ADC framing to LuaSocket's `*l` line pattern
(`receive( socket, "*l" )`, `core/server.lua:565`). That works only because
ADC frames are newline-delimited UTF-8 text. Three independent pieces of
planned work cannot live on a `*l`-framed transport:

- **#82 HTTP API** - request bodies are `Content-Length` / chunked binary.
- **#147 BLOM** - the `HSND` reply has an `m/8`-byte raw-binary data phase
  (may contain `\n`, non-UTF-8).
- **#147 ZLIF** - after `ZON` the wire is an opaque zlib stream; framing
  only exists *after* inflate. Symmetric, partial-flush (Z_SYNC_FLUSH).

All three reduce to one prerequisite: stop letting LuaSocket frame for us;
read raw bytes into a per-connection pipeline that we frame explicitly.
Cross-refs: #82 comment (IO-cluster), #147 (T2.2/T3.2 gated behind this).

## Verified current IO contract (must be preserved byte-for-byte by S1)

Source-read 2026-05-15, `core/server.lua`:

- `receive = socket.receive` (LuaSocket, or luasec-wrapped over TLS),
  `send = socket.send`; assigned at `:773-774`, re-assigned after the TLS
  handshake swap at `:742-743`.
- Single read choke point: `_readbuffer` (`:564`), calls
  `receive( socket, pattern )` with `pattern = "*l"` (`handler.pattern()`
  at `:547` can swap it per connection - the hook point exists, unused for
  binary today).
- Single write choke point: `handler.write` -> `write` (`:531/:546`) ->
  `_sendbuffer` (`:602`) -> `send( socket, buffer, 1, bufferlen )`.
- LuaSocket `*l` nonblocking contract the code relies on (`:565-567`):
  - success: returns the line **without** the `\n`.
  - partial: returns `nil, "wantread"|"wantwrite", partial`. The code
    treats success OR (`part` present and err in {wantread,wantwrite}) as
    "received data" and forwards `buffer or part` to `dispatch`.
  - `timeout` is treated as **fatal** (explicit comment at `:567`).
  - **LuaSocket internally buffers the partial line** across calls - today
    LuaSocket owns line reassembly. Moving to raw bytes moves that
    ownership into our code; this is the core of S1.
- `maxreadlen` cap (`:570`) closes the oversized-frame hole (Phase 7).
- TLS handshake path swaps `receive`/`send` and routes through
  `handler.handshake` (`:760-762`); raw-byte reads must not regress the
  luasec `wantread`/`wantwrite` renegotiation handling.

## Module boundary (CLAUDE.md §2 - do not grow server.lua)

New `core/iostream.lua` owns the per-connection inbound/outbound pipeline.
`server.lua` only: raw bytes -> `iostream` -> framed units -> `dispatch`;
framed write -> `iostream` -> raw bytes -> `send`. server.lua's
select / SSL / timeout / list bookkeeping stays untouched.

## Rollout (incremental, S1 behaviour-neutral first - maintainer-approved)

Each step: own branch off `phase8-io`, own sub-PR into `phase8-io`,
mandatory two-pass pre-merge review (CLAUDE.md §1a.6), full smoke green
(§1b.11). The integration branch merges to master only after the whole
phase passes the review gate.

| Step | Content | Behaviour change |
|---|---|---|
| **S1** | `iostream` with ONLY the ADC-line framer. `*l` receive -> raw read + our own newline reassembly + `maxreadlen` cap. Preserve the wantread/wantwrite/timeout + TLS-handshake contract above exactly. | **none** (proof step) |
| **S2** | Generalise inbound/outbound into a composable pipeline (passthrough stage only) + stage API | none |
| **S3** | HTTP framer stage (#82) | additive (new listener type) |
| **S4** | ZLIF inflate/deflate stage + `ZON`/`ZOF` + zlib build dep | opt-in via SUP |
| **S5** | BLOM counted-binary capture stage + H-class GET/SND | opt-in via SUP |

### Finding 2026-05-15: the old `*l` path has a latent fragmented-frame disconnect bug

Verified against bundled LuaSocket `luasocket/src/buffer.c:105-152`
(`buffer_meth_receive`) + `recvline`:

- `sock:receive("*l")` on an incomplete line returns `nil, errstr,
  <partial>`. errstr is `"timeout"` for plain-TCP nonblocking, or
  `"wantread"`/`"wantwrite"` for the luasec TLS want-dance.
- The old `_readbuffer` guard was
  `if (not err) or (part and (err=="wantread" or err=="wantwrite"))`.
  For a **plain-TCP** frame split across TCP segments, `err=="timeout"`
  -> falls to the `else` branch -> `handler.close` -> **the connection
  is dropped**. TLS partials (`wantread`/`wantwrite`) were tolerated;
  plain-TCP partials were fatal. Asymmetric and fragile.

So the old behaviour for a fragmented frame on plain TCP is "disconnect
the client", almost certainly the root of the historical "Kungen
disconnect bug" / "occasional unwanted disconnects in big hubs"
(server.lua changelog). It rarely bites because small ADC control
frames usually arrive in one TCP segment.

Consequence: "behaviour-neutral" for S1 means neutral w.r.t. the
*intended* behaviour (each complete ADC frame processed exactly once),
**not** bug-for-bug compatible. S1's raw-read + framer **fixes** this
latent disconnect bug. This also upgrades the fragmentation smoke test
from a no-regression check to a genuine pre/post regression test
(fails on old code = connection drops; passes on S1).

### Finding 2026-05-15 (during S1 impl): data + FIN coalescing

The first S1 implementation processed received bytes only on the
benign branch and treated `err == "closed"` as purely fatal (discard,
close). The `+setpass` smoke test failed deterministically. Root cause
(found via instrumented `_readbuffer`): a final TCP segment can carry
both data and the FIN, so `receive( socket, n )` returns
`nil, "closed", <final-bytes>` in a single call. The old `*l` path
never hit this (one line per call; the close arrived as a separate
empty read), so discarding the bytes on "closed" lost the last
command - here a `+setpass` sent immediately before the client closed.
`+help`-style tests masked it (they matched an unrelated login
broadcast frame and passed spuriously); `+setpass`'s strict re-login
assertion exposed it.

Fix: `_readbuffer` now feeds the framer and dispatches complete frames
whenever `got > 0`, **regardless of err**, then performs the close if
the error was terminal. This is the correct read-returns-data-then-EOF
handling and is another strict correctness improvement over the old
path (which could also lose a last command on a fast client close;
rarely bit because clients usually waited for a reply first).

### Finding 2026-05-15 (two-pass review, BLOCKER B1): CR-strip scope

The first framer stripped only a single trailing `\r` before `\n`. The
independent reviewer caught (and the maintainer spot-check confirmed
against `luasocket/src/buffer.c:231-234` recvline, "we ignore all
\r's") that LuaSocket `*l` strips **every** `\r` anywhere in the line.
So `BMSG <sid> a\rb\n` was accepted pre-S1 (`*l` -> `BMSG <sid> ab`)
but rejected post-S1 (embedded CR -> Phase-7 `%c` parser reject ->
silently dropped). The "behaviour-neutral" claim was false - exactly
the §1a.5 "verify every assumption against current source" trap. Fix:
the framer now drops every `\r` in the frame (`gsub`), true `*l`
parity, verified by an embedded-CR framer unit test. This is why the
mandatory two-pass review exists.

### Review findings carried as documented notes (not blocking)

- **C1 - per-tick read pacing changed (acknowledged, not a regression).**
  Pre-S1, `*l` returned one line per `_readbuffer` call; pipelined
  frames sat in LuaSocket's 8 KiB userspace buffer so a flood was
  implicitly throttled to ~1 frame / select-tick / connection. S1
  dispatches all complete frames in the segment in one synchronous
  loop (bounded by `_maxreadlen` = 1 MiB worth, then overflow-close).
  Net: a latency improvement (also fixes a latent pipelined-2nd-frame
  stall) but worst-case synchronous work per tick per connection grew
  from 1 to N frames. There is no per-message ratelimit in the read
  path (ratelimit.lua is per-IP-accept / handshake-deadline only). S2+
  adds heavier per-frame stages (HTTP, ZLIF inflate) and MUST account
  for this - consider a per-tick frame budget when the pipeline lands.
- **C2 - `maxreadlen` cap split.** The framer is constructed once with
  the module-global `_maxreadlen`; the per-frame cap in `_readbuffer`
  uses the per-handler local `maxreadlen`. Equal unless
  `handler.bufferlen()` mutates it - no in-tree caller does (dead
  today). Resolve (pass the live cap into the framer) when S2+ makes
  per-connection caps live.
- **N2 - two-frames smoke test kept as-is.** Reviewer rated it
  adequate; a "two distinct replies" assertion against `+help`'s
  multi-frame reply would add flakiness (worse than the current
  over-merge-caught-via-timeout + desync-caught-via-followup proof).
  Deliberate.

### S1 acceptance (the load-bearing step)

1. Full smoke suite (plain + TLS handshake / login / +cmd routing /
   burst / negative battery) stays green unchanged.
2. New smoke test: an ADC frame delivered split across multiple TCP
   segments (write half a frame, flush, write the rest) is reassembled
   into exactly one processed frame. **This FAILS on pre-S1 code**
   (plain-TCP partial -> "timeout" -> connection dropped) and PASSES on
   S1 - a true pre/post differentiator per CLAUDE.md s1a.7.
3. New smoke test: two ADC frames in a single TCP segment are processed
   as exactly two frames (no over-merge, no drop of the second).
4. error.log gains no new entries during the suite.

S1 is NOT done until 1-4 hold on both Linux (CI) and Windows (local).

### Known highest risk (flagged before any edit)

The luasec TLS path: raw-byte reads over TLS have their own
`wantread`/`wantwrite` semantics during renegotiation, which the current
`*l` code already wrestles with ("SSL nightmare" comments in server.lua
history). S1 preserves the `wantwrite` cross-wiring byte-for-byte and
the handshake coroutine is untouched (the framer is only installed
*after* handshake), and both reviews judged the path logically
equivalent (or better - S1 also keeps the partial on `wantread`).

**GATE RESOLVED 2026-05-15 (not by a test - by removing the cause).**
Re-derived from source instead of building a synthetic reneg test:
`protocol = "tlsv1_3"` makes luasec pin the SSL context to
`min == max == TLS1_3_VERSION` (`luasec/src/context.c:107-111` +
`SSL_CTX_set_min/max_proto_version` at `:337-338`). TLS 1.3 has **no
renegotiation** (RFC 8446). So under the shipped default the
mid-stream `wantread`/`wantwrite` reneg inversion is impossible *by
protocol*, not by luck - the "SSL nightmare" comments predate the
TLS-1.3 default. The only path back to renegotiation was a manual
operator downgrade to `protocol = "tlsv1_2"`. That opt-out is now
removed: the commented `tlsv1_2` blocks are deleted from
`examples/cfg/cfg.tbl` (replaced with an explicit "TLS 1.2 is
UNSUPPORTED" note), and `"no_renegotiation"` (OpenSSL
`SSL_OP_NO_RENEGOTIATION`, luasec `options.c:113-114`) is added to the
default `ssl_params.options` in both `core/cfg_defaults.lua` and
`examples/cfg/cfg.tbl` as defense-in-depth. Dependency constraint:
`no_renegotiation` needs OpenSSL >= 1.1.0h (project bundles 3.x
everywhere; luasec raises "invalid option" on an undefined flag, so a
future OpenSSL downgrade would fail TLS startup loudly, not silently).
Residual want-dance can now only originate from the normal handshake
(framer installed only *after* handshake - untouched) and benign
partial-record reads (handled). Folded into PR #184 as the direct
resolution of this IO-stack review finding.

## S2 spec (locked 2026-05-15, maintainer-approved)

Generalise `core/iostream.lua` from one fixed framer into a
composable per-connection **pipeline of stages**. Behaviour-neutral
proof step (no new functional stage; the S1 ADC-line logic becomes
*a* stage). Decisions:

- **Stage interface (Q1, chosen):** a stage is an object with
  `stage:push( chunk ) -> units, overflow`. `units` is an ordered
  array of whatever this stage emits (the ADC-line stage emits
  complete frame strings; a passthrough stage re-emits its input
  byte chunk as a single unit; future inflate emits decompressed
  byte chunks; future HTTP emits request units). `overflow` is a
  bool only the terminal/framing stage sets (size-cap breach).
- **Pipeline:** `iostream.newpipeline( maxlen )` builds the default
  inbound pipeline = `{ adcline(maxlen) }` and returns an object
  with the **same `:feed( bytes ) -> frames, overflow` contract as
  S1's framer** (so server.lua is a ~2-line change and behaviour is
  provably identical: a 1-stage pipeline == the old framer). `feed`
  runs bytes through stage 1, its units through stage 2, ... ; the
  terminal stage's units are the dispatchable frames.
- **Rebuild seam:** the pipeline exposes an internal `:prepend(stage)`
  so a future stage (S4 ZON -> splice inflate ahead of the framer)
  can rebuild mid-stream. Defined in S2, exercised first in S4 - no
  server.lua hook is added now (YAGNI; the existing unused
  `handler.pattern()` is left as-is, not repurposed).
- **Scope (Q2):** inbound only. The outbound seam is deferred to S4
  (ZLIF deflate); an outbound passthrough now would be speculative.
- Public surface becomes `newpipeline`, `newadclinestage`,
  `newpassthroughstage`; `newframer` is dropped (server.lua is its
  only consumer, verified by grep).

S2 acceptance: the S1 framer unit-test cases pass byte-identically
through the pipeline; a passthrough stage and a `[passthrough,
adcline]` composition behave exactly like `[adcline]`; full smoke
stays green unchanged (neutrality proof). Risk is well below S1 -
the dangerous `*l` -> raw socket change is already shipped; S2 only
restructures the byte/frame flow already in our hands.

## Log

- 2026-05-15: phase opened, integration branch `phase8-io` created, design
  + S1 spec recorded (this doc). IO contract verified against source.
- 2026-05-15: S1 implemented (core/iostream.lua + server.lua _readbuffer),
  commit 36d932c. Two latent bugs found+fixed during impl (plain-TCP
  fragmentation disconnect; data+FIN coalescing). Mandatory two-pass
  review run: independent agent + maintainer spot-check found BLOCKER B1
  (CR-strip scope, false neutrality claim) - fixed (strip all CR, true
  `*l` parity). C1/C2/N1/N2 carried as documented notes above. Smoke
  green 3x on Windows incl. the +setpass test that exposed the FIN bug;
  framer unit-tested incl. embedded-CR. Sub-PR #184 -> phase8-io.
- 2026-05-15: TLS-reneg gate RESOLVED by removing the cause (not a
  test): default is TLS-1.3-only (min==max pin verified in luasec
  context.c; RFC 8446 = no reneg), tlsv1_2 opt-out removed from
  examples/cfg, "no_renegotiation" added to default ssl_params.options
  in cfg_defaults.lua + examples/cfg.tbl as defense-in-depth. Folded
  into PR #184 (direct resolution of the IO-stack review finding).
- 2026-05-15: S1 PR #184 merged into phase8-io (squash 42e2393), all
  CI green (Linux + Windows smoke, image build). S2 spec locked
  (above); branch phase8-io-s2 opened.
- 2026-05-15: S2 implemented (stage pipeline, commit 8336c01),
  behaviour-neutral, full smoke green. Two-pass review: independent
  agent verdict SOUND (no BLOCKER/CONCERN), confirmed by maintainer
  spot-check. Two cosmetic NITs fixed (server.lua phase tag /
  framer->pipeline wording). TEST-DEBT closed in-step rather than
  deferred: added committed `tests/unit/iostream_test.lua` (15
  checks: S1 framer parity + passthrough + composition + prepend
  ordering) - S1/S2 had only throwaway scripts before, which prove
  nothing per s1a.7. **Open gate (S4):** wire
  `tests/unit/iostream_test.lua` into CI before S4 - S4 already
  touches the build/CI for the zlib dependency, so the lua-unit
  runner is in-scope there; the pipeline `prepend` seam gets its
  first production caller in S4 and must be CI-guarded by then.
