---
doc_radar:
  sentinels:
    - description: "the crate root mounts the six modules"
      file: pkg/kernels/irregex/bindings/rust/src/lib.rs
      contains: ["pub mod compose", "pub mod contract", "pub mod exact",
                 "pub mod index", "pub mod relate", "pub mod runtime"]
    - description: "contract module mirrors search_api.toml"
      file: pkg/kernels/irregex/bindings/rust/src/contract/mod.rs
      contains: "ABI_VERSION"
---

# `src/` — Rust `irregex` crate modules

Implementation of the standalone `irregex` / `gist` crate. Parent
[`../README.md`](../README.md) is the crate guide; this README maps modules for
people changing the binding. The six-module shape is mirrored across the Python,
Rust, and Go bindings, so a concept lives in the same place in all three.

| Module      | Job                                                                                                                 |
| ----------- | ------------------------------------------------------------------------------------------------------------------- |
| `lib.rs`    | the facade: crate docs, the free functions, re-exports                                                              |
| `contract/` | the mirrored TOML constants, the generated schema table, grade/channel/unit calibration                             |
| `runtime/`  | the transports and the fallback ladder: FFI decls, analytic dispatch, the one row decoder, subprocess relay, errors |
| `exact/`    | pattern search — request builder, cursor, rank, aggregate                                                           |
| `relate/`   | kinship + retrieval + sweep verbs                                                                                   |
| `compose/`  | the composed verbs: context · family · provenance · blast                                                           |
| `index/`    | artifact lifecycle and status introspection                                                                         |

`schema.gen.rs` sits at this root rather than inside `contract/` because the
generator (`pkg/kernels/irregex/tools/build_schema_tables.py`) owns its path;
`contract/mod.rs` mounts it. Never hand-edit it — a hand edit compiles and then fails the digest
handshake against a real engine.

Parity tests live in [`../tests/`](../tests/) — especially contract parity,
which asserts this crate's constants, schemas, verbs, and grade bands against
the TOML and the live binary.

## When to edit

Widen `contract/search_api.toml` first, then mirror here. Never fork match or
kinship semantics into Rust — drive the certified engine, in-process or out.
