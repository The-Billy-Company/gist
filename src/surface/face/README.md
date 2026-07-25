---
doc_radar:
  counts:
    - description: "cli keeps exactly three product faces: gist · relate · irregex"
      glob: pkg/kernels/irregex/src/surface/face/*
      unit: dirs
      equals: 3
  occurrences:
    - description: "relate's seven verbs are declared once, and the unknown-verb line is rendered from them"
      file: pkg/kernels/irregex/src/surface/face/relate/repertoire.zig
      pattern: '\.run = '
      equals: 7
  sentinels:
    - description: "every face's unknown verb reports the whole repertoire, from that one table"
      file: pkg/kernels/irregex/src/surface/cli/manifest.zig
      contains:
        - "unknown verb '{s}'"
        - "pub fn names("
---

# `src/surface/face/` — the product faces

Thin argv faces over the shared floor. Every binary classifies flags, picks a
verb, and shapes stdout/stderr — they do **not** own matching, walking, or
index formats. If a decision changes what matches, it belongs under
`kernel/`, `corpus/`, or `surface/exec/`.

| Face                  | Binary    | Question it answers                                                                                                                                     |
| --------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`gist/`](gist)       | `gist`    | Where is this exact pattern? (rg-DEFAULT locator + index/status/serve/codex lifecycle)                                                                  |
| [`relate/`](relate)   | `relate`  | What is this text like / which files cover it / what forked? (compression-as-search)                                                                    |
| [`irregex/`](irregex) | `irregex` | The questions that need BOTH engines: exact match narrows a candidate set, compression reasons inside it (`context` · `family` · `provenance`; ADR-367) |

`gist` and `relate` are the direct faces; `irregex` composes their kernels over
one loaded corpus and forwards none of their verbs.

## When to edit here

- A user-visible verb, flag, help string, or `--schema` field changes.
- Exit-code / stdout vs stderr framing changes.
- Daemon auto-spawn or warm eligibility classification changes.

Do **not** put matcher logic, ignore dialects, or persist formats here — those
drift the cold/warm/FFI faces apart the moment one face forks them.

## Invariants

- Unknown flags fail loud (exit 2), never look like a clean empty hit.
- Results on stdout; diagnostics / coaching / timing on stderr.
- Faces stay thin on purpose: cold search re-exports live under
  `surface/exec/cold/`; warm work lives under `surface/exec/session/`.
- Contract authority for request options and relate verbs:
  [`../../../contract/search_api.toml`](../../../contract/search_api.toml).

See [`gist/README.md`](gist/README.md), [`relate/README.md`](relate/README.md),
and [`irregex/README.md`](irregex/README.md) for the per-face verb map and
lifecycle.
