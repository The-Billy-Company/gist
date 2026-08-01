---
doc_radar:
  counts:
    - description: "bindings keep Python, Rust, and Go faces"
      glob: bindings/*
      unit: dirs
      equals: 3
  sentinels:
    - description: "request options live in the engine contract"
      file: ../irregex/contract/engine.toml
      contains: ["[request_options]"]
    - description: "transports live in the surface contract"
      file: ../contract/surface.toml
      contains: ["[transports]"]
---

# `bindings/` — importable kernel faces

Language packages that speak the **same** `SearchRequest → Match` shape as
the `gist` CLI.
They are conveniences over the certified engine — not a second matcher.

| Package             | Import / crate                     | Role                                                              |
| ------------------- | ---------------------------------- | ----------------------------------------------------------------- |
| [`python/`](python) | `gist` → `import gist` | Gist search + Relate kinship through one package                  |
| [`rust/`](rust)     | crate `gist`                       | Same surface for Rust hosts + contract parity tests               |
| [`go/`](go)         | `github.com/The-Billy-Company/gist/bindings/go` | Pull-cursor cgo binding: warm `Engine`, `context`-driven `Cursor` |

## Transport ladder

1. **Subprocess** — authoritative; drives the installed `gist` binary.
2. **UDS warm session** — fail-open accelerator when `gist serve` is up.
3. **In-process FFI** over `libirregex` — Python cffi, the Rust `native`
   feature, and the Go cgo binding all ride the pull-cursor C ABI;
   fail-open, and a bad pattern is a typed error, never a host abort.

Request options are mirrored from
`irregex/contract/engine.toml`;
transports and the tool boundary from
[`../contract/surface.toml`](../contract/surface.toml); the analytic row plane
from `irregex/contract/analytic.toml`; kinship grades and
channels from
`relate/contract/kinship.toml`.
Each package's parity suite asserts the mirrors. Widening the request surface
is a contract change first, bindings second.

## When to edit here

- New request options that already landed in `irregex/contract/engine.toml`.
- Transport failover / session eligibility parity with the CLI.
- Aggregate helpers (`rank`, `summary`, tool-payload adapters).

Per-language docs: [`python/README.md`](python/README.md),
[`rust/README.md`](rust/README.md), [`go/README.md`](go/README.md).
