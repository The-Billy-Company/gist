---
doc_radar:
  sentinels:
    - description: "public C ABI keeps open/search/close + version symbols"
      file: pkg/kernels/irregex/include/irregex.h
      contains: ["irregex_abi_version", "irregex_open", "irregex_search", "irregex_close"]
    - description: "Zig root re-exports the same session surface"
      file: pkg/kernels/irregex/src/root.zig
      contains: "pub const irregex = struct"
---

# `include/` — public C ABI (`libirregex`)

The flat, versioned header non-Zig hosts compile against. One file:
[`irregex.h`](irregex.h). Implementation lives in
[`../src/runtime/ffi/`](../src/runtime/ffi/); `src/root.zig` re-exports the
symbols the shared library ships.

## What the ABI covers

- **Introspection** — `irregex_abi_version`, `irregex_version`,
  `irregex_trigram_count` (allocation-free parity oracle).
- **In-process warm session** — `irregex_open` / `irregex_search` /
  `irregex_close` streaming matches to a callback (ADR-352 rung 3).

Index **build** lifecycle stays a Zig/CLI surface. A session searches the
live tree; it does not mint a new persisted index.

## Invariants

- Status codes, never abort — a bad pattern returns `IRREGEX_STALE` /
  typed failure so the host answers cold.
- Match-callback pointers are valid only for the duration of the callback.
- `nroots == 0` means a rootless CWD walk, cold-identical.
- Bump `irregex_abi_version` on any breaking change; additive symbols do not.

Contract pin: `[meta].abi_version` in
[`../contract/search_api.toml`](../contract/search_api.toml). Python cffi
bindings: [`../bindings/python/`](../bindings/python/).
