# `src/surface/cli/` — the shared face vocabulary

The plumbing every product face speaks to the terminal — argv value parsing,
corpus-root resolution, and result-row emission. It lives here, a sibling of
[`face/`](../face/), so `gist` · `relate` · `irregex` (and relate's kinship
verb-support) share one spelling of a flag value, one root-boundary rule, and
one JSON escaper instead of forking them per binary.

| File | Owns |
| ---- | ---- |
| `flags.zig` | Argv → values + roots: `need` (value after a flag), `count`/`minSize`/`unitFloat` (bounded number parses), `onlyFlag` (lifecycle parse), `Roots`/`rootsOf` (positional → corpus roots), `stripDotSlash` + `underAnyRoot` (path/root membership) |
| `emit.zig` | Result rows: `jsonStr` (the one NDJSON escaper, re-exported from the cold emit floor), `jsonRow` (one object from a comptime field spec), `emitRow` (text vs `--json` off one bool) |

## Why it sits beside `face/`, not inside it

A face is a product binary; this is the vocabulary a face is built from. Both
`irregex` and `relate` verbs — and the kinship view resolver that supports them
— consume it, so hosting it under any one face would force the others to reach
across. Depending downward is fine: `cli/` imports the cold engine's
`die`/`oom` and JSON escaper ([`../exec/cold/`](../exec/cold/)) and the corpus
walk/scope ([`../../corpus/`](../../corpus/)); nothing here imports a face.

## When to edit

Flag-value parse shapes, the corpus-root resolution/membership rule, or the
NDJSON/text row framing. Kinship math and per-verb dispatch stay in
[`face/relate/`](../face/relate/); the composed-verb option surface stays in
[`face/irregex/`](../face/irregex/).
