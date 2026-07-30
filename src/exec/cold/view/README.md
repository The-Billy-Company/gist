---
doc_radar:
  counts:
    - description: "three modules — the dispatch and the two lenses that ship"
      glob: pkg/kernels/irregex/src/exec/cold/view/*.zig
      equals: 3
  sentinels:
    - description: "one seam: a lens is a case in dispatch, and unclaimed is the ordinary rg answer"
      file: pkg/kernels/irregex/src/exec/cold/view/view.zig
      contains: ["pub fn dispatch", "pub const Claim", "unclaimed"]
    - description: "the engine face branches to the dispatch instead of inlining the lenses"
      file: pkg/kernels/irregex/src/exec/cold/engine/serial.zig
      contains: ["view.dispatch"]
    - description: "both lenses read the writ's already-guarded binary verdict rather than re-spelling it"
      file: pkg/kernels/irregex/src/exec/cold/view/commentscope.zig
      contains: ["writ.binaryDetect(o)"]
---

# exec/cold/view — gist's own ways of looking at a match

A **lens** answers the same compiled query over the same PATH scope, but
presents it in a shape ripgrep has no flag for. Two ship today.

| Module             | Lens                                                                                                                                              |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `view.zig`         | the dispatch — picks the lens the flags selected, or answers `unclaimed` and lets the ordinary rg path run                                        |
| `ranked.zig`       | `--rank[=N]` — definition-first RRF over the same hits: the definition outranks its two hundred call sites, and codegen sinks below authored code |
| `commentscope.zig` | `--in-comments` / `--in-code` — the exact engine still decides IF a line matches; the span lexer only filters WHICH matches survive               |

## Why a lens branches early

Each lens finishes the run itself, before the certified rg-parity walk and emit
path. That early return is not a shortcut — it is what keeps the parity
certificate meaningful. A lens **cannot** thread its own awareness through the
machinery `bench/rgsuite/` measures, because it never reaches that machinery.
The rg path stays a byte-for-byte ripgrep drop-in no matter how many native
views gist grows.

## One seam, not a growing ladder

These were two `if` blocks written inline in `serial.run`, and a third lens
would have been a third block. Each one re-derived the file set, re-resolved
rg's filename-visibility rule, and re-spelled the exit shape by hand — so the
cost of a new lens was paid in copies of decisions that already had owners.

`dispatch` writes them once ([ADR-376](../../../../../../docs/architecture/3-decisions/376-cold-engine-deep-modules.md)).
A lens receives a `Run` whose `Writ` already carries every prune guard resolved,
asks `r.collect()` for the file set, `r.showNames(c)` for the filename rule, and
returns a `Claim`. Adding a lens is adding a case.

`Claim` distinguishes the two honest endings: a lens that owns an rg-shaped exit
code never returns at all, while `--rank`'s no-match is an **empty view**
(exit 0), not rg's exit-1 "nothing found" — a difference the old inline `return`
expressed only by being physically inside `run`.

## The file set a lens gets

Lenses read every walked file whole. The whole-file gate and the index
prefilter are both proven against the question _"would this file emit an rg
line?"_, which a lens does not ask — so neither applies. Only the line needle,
a property of the pattern itself, carries over. That reasoning lives in
`collect`, once, rather than in each lens.
