<!-- doc_radar:
paths_exist:
  - bench/conformance/diag/golden.py
sentinels:
  - file: bench/conformance/diag/golden.py
    contains: ["def normalize", "def cmd_check"]
-->

# `bench/diag/` — the diagnostic-template golden net

The safety net for routing every stderr diagnostic through
[`src/assay/`](../../../src/assay/README.md). Each verb-summary / timing / trace
line is a **format template** with volatile values (elapsed `ms`, live counts,
the `atlas,`/`live,` provenance tag) punched in. `golden.py` runs each read-only
verb, captures stderr, and **normalizes the volatile values away** — every digit
run becomes `N`, the provenance tag becomes `SRC` — leaving the template's exact
words, punctuation, and units.

Because the volatile parts are erased, the normalized template is **deterministic
even over the live, concurrently-edited repo**, so it is committed under
`golden/` and diffed in CI. A format typo introduced while moving a line onto
`assay` (`sketches` → `sketch`, a dropped `·`, a changed unit) breaks the
diff; a changed count or timing does not — which is exactly the invariant the
migration preserves: the _shape_ of every diagnostic is unchanged, only the
plumbing beneath it moved.

```bash
zig build -Doptimize=ReleaseFast          # build the three faces first
python3 bench/diag/golden.py check        # CI: diff live templates vs goldens
python3 bench/diag/golden.py update       # regenerate after a deliberate change
python3 bench/diag/golden.py show <name>  # print one verb's normalized template
```

Read-only verbs only — nothing here mutates the shared machine-local index or
atlas. The sibling [`bench/gates/streams.sh`](../gates/contract/streams.sh) proves the
_stream_ contract (results→stdout, stderr silent except the sanctioned
channels); this proves the _content_ templates of that stderr channel.
