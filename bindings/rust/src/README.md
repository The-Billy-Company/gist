---
doc_radar:
  sentinels:
    - description: "the crate root mounts only exact and index"
      file: bindings/rust/src/lib.rs
      contains: ["pub mod exact", "pub mod index"]
      absent: ["pub mod relate", "pub mod compose", "pub mod contract", "pub mod runtime"]
---

# `src/` — Rust `gist` crate modules

Search-only face of the GIST kernel. The shared substrate (`contract`,
`runtime`, `schema.gen.rs`) lives in
[`irregex/bindings/rust`](../../../../irregex/bindings/rust/); kinship and
composed verbs live in their own packages.

| Module | Job |
|---|---|
| `lib.rs` | facade: free functions, re-exports from `irregex` |
| `exact/` | pattern search — aggregate, rank, native cursor |
| `index/` | artifact lifecycle and status introspection |

Parity tests live in [`../tests/`](../tests/).
