---
doc_radar:
  sentinels:
    - description: "SearchRequest is re-exported from the irregex substrate"
      file: bindings/rust/src/exact/mod.rs
      contains: ["pub use irgx::request::{SearchEngine, SearchRequest}"]
    - description: "aggregation reads only real matches, never context lines"
      file: bindings/rust/src/exact/aggregate.rs
      contains: ["MatchKind::Match"]
---

# `exact/` — where a pattern occurs

The `ripgrep`-parity half of the crate: same flags, same precedence, same exit
codes, riding a persisted trigram index.

`SearchRequest` itself lives in `irgx::request` (the engine.toml surface) and
is re-exported here. Aggregation, ranking, and the native cursor stay in this
package because they are gist's product face.

| File | Job |
|---|---|
| `mod.rs` | re-exports `SearchRequest` / `SearchEngine` from `irregex` |
| `cursor.rs` | in-process pull cursor over a warm `Engine` (`native` feature) |
| `rank.rs` | definition-first ranked view (`gist_run`) |
| `aggregate.rs` | grouping a match sequence into counted buckets |

## Ranking

`rank` is gist's one shape with no rg equivalent: a symbol's declaration ahead
of its call sites, with generated files demoted. Classification comes from the
engine, never from this binding.
