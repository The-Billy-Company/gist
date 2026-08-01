The conformance slate now lives here, where the binary it oracles is built.
`bench/conformance/` — the `rg` parity gates, the behavioral-contract gates, the
mined ripgrep drop-in replay, the stderr goldens, the CLI-shape admission
matrix, and the cross-compile target matrix — arrived from the engine package
along with the corpus fetcher that was its only consumer, now at
`bench/apparatus/corpora/`.

The split left it behind, and the seams said so before anyone noticed: the
contract gates already sourced `gist/bench/dominance/races/field.sh`, the target
matrix already pinned `bench/certificate/report/portable.py`, the shapes README
already called itself `gist/bench/matrix`, and half of this repo's own prose
already cited `bench/conformance/…` as a local path. Four parity gates were
resolving the `gist` binary out of the engine's `zig-out`, where it is never
built, so they had been failing to find their subject rather than failing to
prove anything about it.

From here the resolution is what it reads like — `PRODUCT` is this checkout —
and `rgsuite/stress.py`, which finds the binary by walking up three parents, is
correct without being touched. `patterns_corpus_parity.sh` now builds the
sibling `relate` from its own package instead of expecting one `zig-out` to hold
both binaries.

Re-run from `bench/conformance/rgsuite`: 411 of 411 supported cases byte-identical
to ripgrep 15.2.0, on both the parallel and the serial engine.
