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
history). S1 must preserve this exactly; prototype/verify the TLS partial
read before S1 is considered complete - a regression here breaks every
adcs:// connection.

## Log

- 2026-05-15: phase opened, integration branch `phase8-io` created, design
  + S1 spec recorded (this doc). IO contract verified against source.
  Next: S1 design checkpoint, then implement.
