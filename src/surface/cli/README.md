# `src/surface/cli/` — the shared face vocabulary

The plumbing every product face speaks to the terminal — argv value parsing,
result-row emission, the verb table a face is described by, and the stderr
guidance that keeps a weak answer from reading like a strong one. It lives
here, a sibling of [`face/`](../face/), so `gist` · `relate` · `irregex` (and
relate's kinship verb-support) share one spelling of a flag value, one root
boundary rule, one JSON escaper, and one hint grammar instead of forking them
per binary.

| File           | Owns                                                                                                                                                                                                                                            |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `flags.zig`    | Argv → values + roots: `need` (value after a flag), `count`/`minSize`/`unitFloat` (bounded number parses), `onlyFlag` (lifecycle parse), `Roots`/`rootsOf` (positional → corpus roots), `stripDotSlash` + `underAnyRoot` (path/root membership) |
| `emit.zig`     | Result rows: `jsonStr` (the one NDJSON escaper, re-exported from the cold emit floor), `jsonRow` (one object from a comptime field spec), `emitRow` (text vs `--json` off one bool)                                                             |
| `manifest.zig` | The verb table a face declares itself as (`Face`/`Verb`/`Flag`/`Retired` with typed defaults), and the renderings derived from it: `--help`, the `--schema` JSON manifest with its shared envelope, verb dispatch, and the unknown-verb line — which coaches a retired spelling to the invocation that replaced it |
| `grade.zig`    | The surface half of kinship judgment (the `Channel`/`Grade` vocabulary itself is a kernel fact, re-exported here): `Sift`, the shared emit ledger every ranking verb runs — cap, drop vanished rows, remember the strongest score, withhold under `--min-grade` — and the `Verdict` it reports when an answer is weak |
| `guide.zig`    | The stderr guidance grammar both gist's no-match hints and relate's verdicts speak: `tool: try …` / `tool: note: …` lines under a shared budget                                                                                                 |
| `outcome.zig`  | The process exit code: ripgrep's `0`/`1`/`2` contract computed in one place, including the two precedences (a fault normally outranks a match; under `--quiet` a match outranks a fault)                                                        |

## Why it sits beside `face/`, not inside it

A face is a product binary; this is the vocabulary a face is built from. Both
`irregex` and `relate` verbs — and the kinship view resolver that supports them
— consume it, so hosting it under any one face would force the others to reach
across. Depending downward is fine: `cli/` imports the cold engine's
`die`/`oom` and JSON escaper ([`../exec/cold/`](../exec/cold/)) and the corpus
walk/scope ([`../../corpus/`](../../corpus/)); nothing here imports a face.

## When to edit

Flag-value parse shapes, the corpus-root resolution/membership rule, the
NDJSON/text row framing, how a face renders itself, or what a kinship score is
worth. What each face's verbs _are_ stays in that face's `repertoire.zig`
([relate](../face/relate/repertoire.zig) ·
[irregex](../face/irregex/repertoire.zig)) — this directory renders a verb
table, it never enumerates one. Kinship math stays in
[`face/relate/`](../face/relate/) and
[`kernel/kinship/`](../../kernel/kinship/).
