# exec/session/daemon/client — warm dial + cold fallback

The fail-open bridge from the bare `gist <pattern>` front door to the resident
daemon ([`../serve`](../serve)). Warm acceleration is opportunistic; correctness
always has the cold engine behind it.

`attempt(gpa, io, argv, socket_path)` classifies the argv
(`irregex/src/exec/session/answer/request.zig`) and only dials when
the request is one the warm path can answer with **cold's own per-file bytes
and exit code**:

- `-l` / `--files-with-matches` — sorted path list
- bare default line search (`gist <pattern> [-n]`) — `path:[line:]text` frames
  the daemon pre-renders through the cold `Emitter` and chunk-streams
- `--rank[=N]` — the definition-first ranked view; the daemon ranks over
  resident bytes and streams the rendered top-K on the same transport

File emission order is the deterministic `pathLess` canonicalization of cold's
parallel worker-discovery order (rgsuite certifies
`sort_lines(gist) == sort_lines(rg)`). Anything else — ineligible argv, no
daemon, a `decline`, any wire hiccup — returns `.cold` and the caller runs the
certified cold path unchanged.

**Parity guards.** TTY stdout declines to cold (interactive cold adds ANSI + the
16 KiB long-line cap; the daemon renders the piped frame only). Readable stdin
declines to cold (a rootless stream search the tree daemon can never answer).
`-c` and richer shapes stay cold.

**I/O deadline.** After connect, every warm `recvFrame` is gated by
`poll(…, client_io_timeout_ms)` (2s). A peer that accepts but never speaks READY
cannot park the CLI — timeout falls through to `.cold` (`client_test.zig`).

**Autoserve.** On a cold miss for an eligible shape, `spawn.zig::maybeSpawn`
best-effort forks a detached `gist serve` so the _next_ query lands warm. The
current query still runs cold. Opt out with `GIST_NO_AUTOSERVE`. Ten agents
racing the socket is the normal case: the daemon takes an advisory `flock`, so
exactly one serve wins.

**Which build is on the other end.** Framing alike is not answering alike. A
daemon from a superseded build speaks the same wire version and returns a
well-formed answer computed by an engine this binary no longer shares — the one
shape a search tool may never take. So READY carries the daemon's build stamp
([`../../../../exec/session/conduit/image.zig`](../../../../exec/session/conduit/image.zig)) and the
client declines any peer it does not `agree` with, exactly as it declines a wire
version it does not speak.

Declining alone would strand the warm tier: the daemon's idle TTL wants ten
*continuous* minutes of quiet, which a tree with ten coworker agents never
gives it, so one `zig build` would mean cold queries for the rest of the
day. On the way out to cold, a client that is **strictly newer** — a higher wire
version, or a later build stamp — sends `shutdown`. The order is one-directional
on purpose: a symmetric "we disagree, so you stop" rule has an old shell and a
new one taking turns killing each other's daemons all afternoon. This way the
skew converges after a single cold query, and the next eligible one auto-spawns
from the binary that won.

`residency(gpa, io, socket_path)` is the same judgement asked as a question
rather than acted on: `none` / `ours` / `foreign`, no spawn and no retire. It
is what `gist status` prints, so a skew is legible before it costs an afternoon.

**Answer keep.** `keep.zig` is the caller's side of the answer-keep protocol.
A verb whose answer is a pure function of the corpus (relate and irregex
kinship/composed verbs) runs a three-step errand: ask the daemon whether it
still holds the answer to this exact question; if not, compute cold; then offer
the rendered bytes back, stamped with the epoch read before the work began. The
daemon keeps them only if the corpus has not moved since. Every failure is
silence — the verb runs as if this module did not exist.

The keep is the one handshake that does **not** judge the build, and the reason
is structural: its callers are `relate` and `irregex`, two binaries dialing
gist's daemon, so a stamp mismatch there is the normal state rather than a skew.
It stays safe without one because a kept answer is bytes the *client* rendered
and offered, held against a corpus epoch — the daemon never computes it, so a
daemon of another vintage cannot put its own engine's output in the reply.
