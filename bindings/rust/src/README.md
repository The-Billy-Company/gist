---
doc_radar:
  sentinels:
    - description: "crate root re-exports the SearchRequest surface"
      file: pkg/kernels/irregex/bindings/rust/src/lib.rs
      contains: ["SearchRequest", "pub mod"]
    - description: "contract module mirrors search_api.toml"
      file: pkg/kernels/irregex/bindings/rust/src/contract.rs
      contains: "ABI_VERSION"
---

# `src/` — Rust `gist` crate modules

Implementation of the standalone `gist` crate. Parent
[`../README.md`](../README.md) is the crate guide; this README maps modules
for people changing the binding.

| Module | Job |
| ------ | --- |
| `lib.rs` | Public re-exports and crate docs |
| `request.rs` | `SearchRequest`, match / rank kinds |
| `engine.rs` | Subprocess transport (authoritative) |
| `session.rs` | UDS warm-session client (fail-open) |
| `contract.rs` | Mirrored constants from `contract/search_api.toml` |
| `aggregate.rs` | Summary / tally helpers |
| `error.rs` | Typed errors (`UnsupportedPattern`, …) |

Parity tests live in [`../tests/`](../tests/) — especially `contract.rs`,
which asserts this crate's constants against the TOML and the live binary.

## When to edit

Same rule as Python: widen `search_api.toml` first, then mirror here. Never
fork match semantics into Rust — drive the certified `gist` binary / session.
