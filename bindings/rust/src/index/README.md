---
doc_radar:
  sentinels:
    - description: "the three persisted artifacts of the two engines"
      file: pkg/kernels/irregex/bindings/rust/src/index/mod.rs
      contains: ["Trigrams", "Atlas", "Shelf"]
---

# `index/` — the artifacts, and what state they are in

Three persisted artifacts, one per thing an engine wants to stop recomputing:
the **trigram index** that prefilters exact search, the **kinship atlas** that
snapshots every file's compression sketch and structure silhouette, and the
**codex shelf** that `quote` and `provenance` attribute phrases against.

The load-bearing property is that **none of them is a dependency**. Every verb
in this crate answers correctly with no artifact at all — the engine degrades to
a live walk and says so in `Stats::tier`. An artifact changes what a question
_costs_, never what it _answers_. A warm answer folds in whatever changed since
the artifact's anchor, so a stale artifact stays correct and merely prunes less.
That is why `build` and `status` are the whole surface: there is no "is the
index required" question to expose, because the answer is always no.

This module also carries the two facts a host needs to _report_ which tier it is
paying for — whether an in-process analytic plane answered this process's symbol
probe, and the schema digest this build's decoder was generated from. Comparing
that digest against another binding's is how two languages prove they speak the
same rows without either reading the other's generated table. Neither is
something a caller should branch on: the ladder falls through to the subprocess
tier for the identical answer.
