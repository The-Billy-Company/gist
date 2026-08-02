# `src/surface/face/` — the product faces

Thin argv faces over the shared floor. Every binary classifies flags, picks a
verb, and shapes stdout/stderr — they do **not** own matching, walking, or
index formats. If a decision changes what matches, it belongs under
`kernel/`, `corpus/`, or `exec/` in the engine packages.

| Face                  | Binary    | Question it answers                                                                                                                                                                                                                                                   |
| --------------------- | --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`gist/`](gist)       | `gist`    | Where is this exact pattern? (rg-DEFAULT locator + index/status/serve/codex lifecycle)                                                                                                                                                                                |

The `relate` face lives in the `relate` package (`relate/src/surface/face/`);
the composed `irregex` face lives in `blast`. Both import this chassis for
the resident daemon and the answer keep.

## When to edit here

- A user-visible verb, flag, help string, or `--schema` field changes.
- Exit-code / stdout vs stderr framing changes.
- Daemon auto-spawn or warm eligibility classification changes.

Do **not** put matcher logic, ignore dialects, or persist formats here — those
drift the cold/warm/FFI faces apart the moment one face forks them.

## Invariants

- Unknown flags fail loud (exit 2), never look like a clean empty hit.
- Results on stdout; diagnostics / coaching / timing on stderr.
- Faces stay thin on purpose: cold search lives in `irregex`; warm work
  lives under `exec/session/` here.
- Contract authority for request options:
  `irregex/contract/engine.toml`.

See [`gist/README.md`](gist/README.md) for the per-face verb map and
lifecycle.
