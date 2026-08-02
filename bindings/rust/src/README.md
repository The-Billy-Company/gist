# `src/` — Rust `gist` crate modules

Search-only face of the GIST kernel. The shared substrate (`contract`,
`runtime`, `schema.gen.rs`) lives in
[`irregex/bindings/rust`](../../../../irregex/bindings/rust/); kinship and
composed verbs live in their own packages.

| Module | Job |
|---|---|
| `lib.rs` | facade: free functions, re-exports from `irregex` |
| `contract.rs` | mirror of this repo's `contract/surface.toml` — published names, tool boundary |
| `exact/` | pattern search — aggregate, rank, native cursor |
| `index/` | artifact lifecycle and status introspection |

Parity tests live in [`../tests/`](../tests/).
