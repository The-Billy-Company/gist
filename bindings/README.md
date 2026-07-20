---
doc_radar:
  counts:
    - description: "bindings keep Python and Rust faces"
      glob: pkg/kernels/irregex/bindings/*
      unit: dirs
      equals: 2
  sentinels:
    - description: "both faces mirror the unified search contract"
      file: pkg/kernels/irregex/contract/search_api.toml
      contains: ["[request_options]", "[transports]"]
---

# `bindings/` — importable kernel faces

Language packages that speak the **same** `SearchRequest → Match` shape as
the `gist` CLI ([ADR-352](../../../../docs/architecture/3-decisions/352-gist-unified-search-api.md)).
They are conveniences over the certified engine — not a second matcher.

| Package | Import / crate | Role |
| ------- | -------------- | ---- |
| [`python/`](python) | `billy-irregex` → `import irregex` | Gist search + Relate kinship through one package |
| [`rust/`](rust) | crate `gist` | Same surface for Rust hosts + contract parity tests |

## Transport ladder

1. **Subprocess** — authoritative; drives the installed `gist` binary.
2. **UDS warm session** — fail-open accelerator when `gist serve` is up.
3. **In-process FFI** (Python cffi over `libirregex`) — fail-open; never
   aborts the host on a bad pattern.

Constants and option names are mirrored from
[`../contract/search_api.toml`](../contract/search_api.toml) and asserted in
each package's parity suite. Widening the request surface is a contract
change first, bindings second.

## When to edit here

- New request options that already landed in `search_api.toml`.
- Transport failover / session eligibility parity with the CLI.
- Aggregate helpers (`rank`, `summary`, tool-payload adapters).

Per-language docs: [`python/README.md`](python/README.md),
[`rust/README.md`](rust/README.md).
