---
doc_radar:
  sentinels:
    - description: "an answer reports its own tier and the two truncation facts"
      file: pkg/kernels/irregex/bindings/rust/src/runtime/answer.rs
      contains: ["Tier::Subprocess", "foreign", "omitted"]
    - description: "STALE is a declinature, never an Err"
      file: pkg/kernels/irregex/bindings/rust/src/runtime/plane.rs
      contains: ["STALE", "Ok(None)"]
    - description: "the digest handshake precedes any native decode"
      file: pkg/kernels/irregex/bindings/rust/src/runtime/handshake.rs
      contains: ["schema::DIGEST", "first_disagreement"]
---

# `runtime/` — how a question reaches the engine, and how rows come back

Everything above this module states _what_ it wants. This module is the only
place that knows _how_ it is answered — and, when the fast way is unavailable,
that the slow way gives the same answer.

## The ladder

An analytic call tries, in order:

1. **In-process** (`plane.rs`) — `irregex_analytic_run` over a cached engine
   handle, rows pulled from the kernel's arena with no copy and no parsing.
2. **Subprocess** (`relay.rs`) — the certified CLI with `--json`, its NDJSON
   lowered through the _same_ schema table into the same rows.

Each rung is skipped, never failed, for three reasons: the crate was built
without the `native` feature, the loaded library predates the analytic exports
(symbol probe comes back empty), or the engine answered `IRREGEX_STALE`. That
last one is the subtle one — **stale is a declinature, not an error**. The
engine is saying "I could answer this, but not from what I have warm"; the
correct response is to ask the next tier, and the caller must never see it. An
`Err` escaping the ladder means something genuinely broke.

Exact search keeps its own two rungs — the resident `gist serve` daemon
(`session.rs`, Unix) and the cold subprocess (`shell.rs`) — for the same
fail-open reason. Its two answers are printed, not emitted, so they are parsed
apart from the schema table in `readout.rs`: ripgrep's `--json` records are a
foreign contract held byte-for-byte, and `--rank` predates `--json` and still
prints for people.

A subprocess answer is also bounded on both ends. The child is killed if it
outlives the request timeout, and — the subtler one — its drained streams are
taken after a short grace once it exits, because the engine self-spawns the
resident daemon and that grandchild inherits the write end of our pipe. Waiting
for EOF there would mean waiting out the daemon's whole lifetime for bytes that
were already written.

Which rung answered is never a guess: every answer carries `Stats::tier`, which
distinguishes a live walk from an atlas fold from the codex shelf from an
out-of-process CLI, alongside `foreign` (fingerprints the corpus has never seen
— "your text isn't in this repo", not "no results") and `omitted` (a budget
truncated the tail).

## One decoder for seventeen verbs

Every analytic verb returns the same self-describing row, so the crate has one
decoder rather than one result type per verb, and both transports lower into
it. `decode.rs` walks `SCHEMAS[schema_id - 1]` positionally over the value
array and `lower.rs` walks the same table over CLI JSON; `cell.rs` is the value
model in its borrowed and owned forms; `verify.rs` is the single pass that makes
every accessor afterwards infallible; `answer.rs` is the cursor, its batches,
and the answer-level stats.

Three decisions in there are load-bearing:

- **Absent is not zero.** `distance = 0.0` means _identical_, so a field the
  engine did not set has to be `None`, never a sentinel. The presence mask is
  the authority, and a value array shorter than the schema reads as absence
  rather than an out-of-bounds read.
- **An unknown ordinal stays unknown.** `[row_enums]` is append-only, so an
  ordinal past this build's table means a newer engine. Guessing would silently
  mislabel a grade; the row keeps the raw ordinal instead.
- **A row borrows its cursor.** The next pull invalidates the arena, and the
  borrow checker is what enforces that — not a doc comment. `to_owned()` is the
  explicit way out, and it is a deep copy including nested rows.

## The handshake

Before the first native row is decoded, `handshake.rs` compares the generated
`DIGEST` against `irregex_schema_digest()`. Equal, and the plane is live.
Different, and the plane refuses **loudly** — walking the engine's own schema
table to name the schema or field that drifted, because "row 4 field 7 looks
wrong" is not something a caller can act on. A missing symbol is a downgrade; a
drifted digest is a failure. Mis-decoding a row whose shape changed underneath
us is the one outcome worth failing to avoid.

## When to edit

Adding a verb is a contract change first (`contract/search_api.toml`), then a
generator run, then a builder in `relate/` / `compose/`. It should require
nothing here. If it does, the ladder has grown a special case — prefer widening
`Query` over branching on the verb.
