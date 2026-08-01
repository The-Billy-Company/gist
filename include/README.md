---
doc_radar:
  sentinels:
    - description: "public C ABI keeps open/search/close + session version symbols"
      file: include/gist.h
      contains: ["gist_abi_version", "gist_open", "gist_search", "gist_close", "gist_run"]
    - description: "Zig root exports the same session surface"
      file: src/root.zig
      contains: ["export fn gist_open", "export fn gist_run", "export fn gist_abi_version"]
---

# `include/` — public C ABI (`libgist`)

The flat, versioned header non-Zig hosts compile against. One file:
[`gist.h`](gist.h). It `#include`s `<irregex.h>` for the substrate (status
codes, fault pull, row cursor). Implementation lives in
[`../src/surface/ffi/`](../src/surface/ffi/); `src/root.zig` exports the
`gist_*` symbols the shared library ships. Link `libgist` and `libirregex`.

## What the ABI covers

- **Introspection** — `gist_abi_version` (session axis), `gist_trigram_count`.
  Engine version / PCRE version / schema digest come from `libirregex`.
- **In-process warm session** — `gist_open` / `gist_search` / `gist_close`.
- **Pull cursor** — `gist_engine_open` / `gist_search_cursor` / `gist_cursor_*`.
- **Rank producer** — `gist_run` for `GIST_OP_RANK`, returning an
  `irregex_rows *` walked by `irregex_rows_*` from `libirregex`. Kinship and
  sweep are `relate_run` in `relate.h`; compose is `blast_run` in `blast.h`.

Index **build** lifecycle stays a Zig/CLI surface. A session searches the
live tree; it does not mint a new persisted index.

## Invariants

- Status codes, never abort — a bad pattern returns `IRREGEX_STALE` /
  typed failure so the host answers cold.
- Match-callback pointers are valid only for the duration of the callback.
- `nroots == 0` means a rootless CWD walk, cold-identical.
- Bump `gist_abi_version` on any breaking session change; additive symbols do
  not. The engine plane versions independently via `irregex_abi_version`.

Contract pin: `[meta].abi_version` in the sibling kernel checkout's
`irregex/contract/engine.toml`
(or set `IRREGEX_ENGINE_CONTRACT`). Python cffi bindings:
[`../bindings/python/`](../bindings/python/).
