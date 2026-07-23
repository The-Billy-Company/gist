---
doc_radar:
  counts:
    - description: "exec keeps exactly the two engine rungs"
      glob: pkg/kernels/irregex/src/surface/exec/*
      unit: dirs
      equals: 2
  sentinels:
    - description: "cold serial engine remains the root search re-export"
      file: pkg/kernels/irregex/src/root.zig
      contains: 'pub const search = @import("surface/exec/cold/engine/serial.zig");'
---

# `src/surface/exec/` — the search engines

Where a compiled query meets a corpus. `exec/` owns the *execution* rungs that
drive `corpus/` + `kernel/` — walk, read, match, emit — without owning any
product UX: no verb tables, no `--help` copy, no NDJSON shapes. A `face/`
imports these engines; an engine never imports a face.

| Rung                        | Transport          | Job                                                                                                          |
| --------------------------- | ------------------ | ------------------------------------------------------------------------------------------------------------ |
| [`cold/`](cold)             | 1 (subprocess)     | The certified rg-DEFAULT drop-in: argv → walk → read → match → emit; serial / parallel / ranked, plus relate's cold retrieval engine |
| [`session/`](session)       | 2.5 (UDS daemon)   | The resident corpus + index behind `gist serve`; every entry point returns errors, never `die()`             |

## The one match opinion

The warm daemon does **not** reimplement matching. Both rungs lower every query
through the shared `kernel/match/query.zig` core, and `session/` reuses `cold/`'s
own `Emitter` / `grepfile` / file-set machinery, so warm bytes cannot become a
second opinion:

- **Fail open to cold.** Any warm decline, timeout, TTY, wedged daemon, or
  reconcile doubt falls back to the certified cold subprocess.
- **Index accelerates only.** Missing / stale / `--no-index` → live scan,
  never different bytes.
- **cold owns the walk.** `session/` re-derives its file set from
  `cold/engine/serial.zig::defaultFileSet` on every reconcile — never a coarser
  superset — so `resident == gist --no-index == rg`.

The in-process C-ABI rung 3 lives beside this one in [`../ffi`](../ffi); it
shares the resident session but is documented there.

Deep dives: [`cold/README.md`](cold/README.md),
[`session/README.md`](session/README.md).
