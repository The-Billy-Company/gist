# bench/apparatus

The **ground the races run over**, and the instruments that measure it. Nothing
here makes a claim; everything here is what `conformance/`, `dominance/`, and
`certificate/` measure _with_.

Most of this directory is **vendored**: the same bytes live at
`bench/apparatus/` in `irregex`, `relate`, and `blast`, pinned by
`SHARED.sha256` and held identical by `shared_drift.py`. Four independently
releasable packages cannot import Python or source shell across a repository
boundary, and two copies that answer "where are my siblings", "what is the
corpus", or "is this difference significant" differently is how two certificates
quietly stop being comparable. What is shared is the **method**; what each
package **claims** stays with that package.

| Piece                           | What                                                                                                                                                            |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`corpora/`](corpora/README.md) | the corpus itself — `fetch.sh` assembles it, `torture.py` synthesizes adversarial trees, `sweep.py` walks size regimes                                          |
| [`harness/`](harness/README.md) | the `gist-bench` binary — one executable, six modes (`bench` · `verify` · `session` · `certify` · `flagbench` · `sessionprof`), which every lane below drives    |
| `roots.sh` ⟨vendored⟩           | where this package and its siblings are: `KERNEL` (this checkout), `CORPUS` (the tree measured), `ENGINE` / `PRODUCT` / `KINSHIP` (the irregex / gist / relate checkouts) |
| `field.sh` ⟨vendored⟩           | the measurement floor — corpus scope + ignore set, csearch/zoekt index construction, and the hyperfine/oracle helpers that decide when a timing is allowed to count |
| `provenance.py` ⟨vendored⟩      | the three artifacts that make a number re-derivable — `machine.json`, `tool-versions.txt`, `corpus-manifest.tsv`                                                |
| `statcore.py` ⟨vendored⟩        | bootstrap CIs and the Mann-Whitney verdict, so "significant" means one thing everywhere                                                                         |
| `shared_drift.py` ⟨vendored⟩    | the gate over all of the above — recompute, compare to the pinned manifest, and `--propagate` a deliberate edit to every sibling                                |

**One name, one meaning.** A checkout is `KERNEL`; a tree being measured is
`CORPUS`. There is deliberately no `REPO`: it used to mean the corpus in
`roots.sh` and the package in `field.sh`, which is how a mint came to hash a
corpus manifest relative to the checkout while its path list was relative to a
snapshot — every row a real file with a real digest, and none of them the bytes
that were searched.

`field.sh` here is the apparatus; `dominance/races/field.sh` is the roster. The
split is the same one the vendoring draws: *how* a rival is indexed and timed is
identical in every package, *which* rivals gist races and how each is invoked is
gist's alone.

`harness/` holds the binary but not the instruments. The 12-class probe
registry, the PMU counters, and the bootstrap/Mann-Whitney verdict math stay
with the engine at `irregex/bench/apparatus/harness/` and arrive here as the
`probes` / `pmu` / `stats` Zig modules through the `irregex` dependency — one
registry and one significance test across both repos, so a race arm here and an
engine rung there are comparable by class name.
