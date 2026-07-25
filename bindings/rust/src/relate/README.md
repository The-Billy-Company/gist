---
doc_radar:
  sentinels:
    - description: "the kinship, retrieval, and sweep families are all present"
      file: pkg/kernels/irregex/bindings/rust/src/relate/mod.rs
      contains: ["pub fn similar", "pub fn dups", "pub fn clusters", "pub fn echoes",
                 "pub fn pack", "pub fn quote", "pub fn patterns"]
    - description: "kinship answers are graded, not just scored"
      file: pkg/kernels/irregex/bindings/rust/src/relate/kinship.rs
      contains: ["min_grade", "Grade"]
---

# `relate/` — search by resemblance, not by pattern

Exact search needs you to already know how the thing is spelled. These verbs do
not. They price one text against another by **how cheaply each compresses the
other**, which makes them the answer to the questions a regex cannot phrase:
what resembles this file, which files jointly explain this paragraph, where a
pasted snippet came from.

Three families live here, split by the question shape rather than by the wire:

- **Kinship** (`kinship.rs`) — `similar` · `dups` · `clusters` · `echoes` ·
  `concepts` · `fragments` · `distinct`. Given a file (or none, for a corpus sweep), which
  other files are kin. `similar` ranks neighbors; `dups` lists near-duplicate
  pairs; `clusters` returns the _fork family_ — the restructure-ready unit a
  pair list makes you re-derive by hand; `echoes` finds the kin `dups` cannot
  see, where the skeleton is shared but the vocabulary was renamed.
- **Retrieval** (`retrieval.rs`) — `recall` · `pack` · `quote`.
  Given text, which files answer it. `pack` is the one worth knowing: it prices
  each pick by the bits it adds _beyond the picks already chosen_, so a
  near-duplicate of an earlier pick can never make the cut, and the result is a
  reading set rather than a ranked list with the same file three times.
- **Sweep** (`sweep.rs`) — `patterns` · `pattern_counts`. N patterns, one walk,
  exact per-pattern attribution.

## Grades, because a score is not an answer

Every kinship row carries a calibrated band alongside its raw distance. This is
not decoration: a corpus always has a nearest neighbor, so an ungraded `similar`
will happily print five strangers at 0.78 as though they were kin.
`min_grade(Grade::Strong)` withholds them, and an empty answer is the honest
one. Polarity is handled for you — `twins` is a gap where the other channels are
distances, so "stronger" means a bigger number there and a smaller one
elsewhere.

## Shape of a call

Each verb is a builder that ends in `.rows()`, returning the same cursor every
analytic verb returns. Defaults come from `[analytic.verbs]` in the contract, so
an unset knob means _the engine's default_, not a value this crate invented.

```rust
let fam = gist::relate::clusters().min_size(3).root("pkg/kernels").rows()?;
for row in fam.iter() { /* … */ }
```

## When to edit

A new kinship channel or verb is a `contract/search_api.toml` change plus a
generator run; the builder here should only ever name parameters that already
exist in `[analytic.params]`.
