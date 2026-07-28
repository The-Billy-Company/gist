# Committed evaluation bundles

One directory per machine (`<machine-id>/bundle.json` + `corpus-manifest.tsv`),
published by `evaluate.py run --publish` from a **clean git tree** after the
bundle passes the full `performance_evidence.toml` contract. `REPORT.md` is the
generated cross-machine aggregate.

These are **machine-labeled**: `apple-*-darwin-arm64` and `*-linux-x86_64`
(Anvil) are separate evidence, never averaged. Absolute build ms, RSS, and qps
are local to each machine; only the index/corpus footprint ratio and scaling
shape are compared across them (`evaluate.py compare` / the footprint-consistency
section of `REPORT.md`). Cold/warm query dominance lives in the
[Dominance-and-Fit Certificate](../../certify/), not here.

Regenerate rather than hand-edit: `make gist-evaluate` (measure) →
`make gist-evaluate-verify` (hermetic contract + claim check, the CI path).
