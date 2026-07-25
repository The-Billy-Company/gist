---
doc_radar:
  sentinels:
    - description: "the generated schema table is mounted, not re-declared"
      file: pkg/kernels/irregex/bindings/rust/src/contract/mod.rs
      contains: ['#[path = "../schema.gen.rs"]', "pub mod schema"]
    - description: "the four row_enums vocabularies have typed faces"
      file: pkg/kernels/irregex/bindings/rust/src/contract/calibration.rs
      contains: ["Grade = 1", "Channel = 2", "Unit = 3", "row_enum!"]
---

# `contract/` — what the engine promises, in Rust

This module is the crate's copy of `contract/search_api.toml`. Nothing here
runs; everything here is what the rest of the crate is _allowed to assume_.

It carries the contract in two forms, and the difference matters:

- **Hand-mirrored constants** — ABI version, engine version, request options,
  match kinds, exit codes, the tool-boundary aliases. Small, stable, and read
  by humans, so they are written out and held to the TOML by the parity test in
  `../../tests/contract.rs`. The crate embeds them rather than reading the file
  at runtime, because an OSS checkout ships without the repo around it.
- **The generated analytic tables** — `schema.gen.rs`, lowered from the same
  TOML by `pkg/kernels/irregex/tools/build_schema_tables.py` and mounted here
  by path. Seventeen
  verbs, twenty-two row schemas, and their field lists are far too much surface
  to keep in step by hand, so no one does: the generator owns that file, and
  `DIGEST` is what proves a loaded engine agrees with it.

## Calibration — where a number becomes a judgment

`calibration.rs` holds the four closed vocabularies a row field can carry
(`Grade`, `Channel`, `Unit`, and the raw `Variant` an unresolvable ordinal stays
as) together with the bands that give a score meaning. A distance of 0.78 is not
"the eighth-nearest file", it is _background_ — so every kinship row carries a
grade, and a caller filtering on `>= Grade::Strong` gets an empty answer instead
of five strangers. Polarity lives here too, because `twins` is a gap where every
other channel is a distance, and one band table cannot serve both.

`[row_enums]` is **append-only**. An ordinal past the end of this build's table
is a newer engine, not corruption, so `Variant` keeps it verbatim and `name()`
reports `None` — the caller decides whether unknown is fatal for its question.

## When to edit

Widen `contract/search_api.toml` first, then mirror. For anything under
`[row_schemas]` / `[row_enums]` / `[analytic.verbs]`, re-run the generator
instead of touching `schema.gen.rs` — a hand edit will pass `cargo build` and
fail the digest handshake against a real engine.
