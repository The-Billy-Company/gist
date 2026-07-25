---
doc_radar:
  sentinels:
    - description: "the request builder is the one place argv is shaped"
      file: pkg/kernels/irregex/bindings/rust/src/exact/request.rs
      contains: ["pub struct SearchRequest", "fn to_argv"]
    - description: "aggregation reads only real matches, never context lines"
      file: pkg/kernels/irregex/bindings/rust/src/exact/aggregate.rs
      contains: ["MatchKind::Match"]
---

# `exact/` — where a pattern occurs

The `ripgrep`-parity half of the crate: same flags, same precedence, same exit
codes, riding a persisted trigram index. Everything a caller can ask goes
through one `SearchRequest`, which is also the only place in the crate that
knows how to shape CLI argv — so the resident session, the cold subprocess, and
the in-process cursor cannot drift into three dialects of the same request.

| File           | Job                                                                |
| -------------- | ------------------------------------------------------------------ |
| `request.rs`   | the builder, its argv lowering, and `search`/`files`/`count`       |
| `cursor.rs`    | the in-process pull cursor over a warm `Engine` (`native` feature) |
| `rank.rs`      | the definition-first ranked view                                   |
| `aggregate.rs` | grouping a match sequence into counted buckets                     |

## Ranking, and why the crate never re-classifies

`rank` is gist's one shape with no rg equivalent: a symbol's declaration ahead
of its two hundred call sites, with generated files demoted because the repo
forbids editing them. The `def` / `use` / `gen` label is read straight off the
engine's own output and never recomputed here — a second classifier in Rust
would silently fork from the kernel's the first time either changed.

## Aggregation is a result-side layer

`summary` / `tally` group matches you already have; they never run a second
matcher and never widen the request. Only real match lines are counted, so
`-A/-B/-C` context can't inflate a tally. Keeping it pure is what makes it
testable without the binary.

## When to edit

A flag exists here only if the CLI already accepts it. Match semantics live in
the Zig engine — this module builds the request and reads the answer, and any
temptation to "just handle that case in Rust" is a fork of the matcher.
