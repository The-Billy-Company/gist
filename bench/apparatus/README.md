# bench/apparatus

The **ground the races run over**, and the resolver that finds it. Nothing here
makes a claim; everything here is what `conformance/`, `dominance/`, and
`certificate/` measure _with_.

| Piece                           | What                                                                                                                                                                    |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`corpora/`](corpora/README.md) | the corpus itself — `fetch.sh` assembles it, `torture.py` synthesizes adversarial trees, `sweep.py` walks size regimes                                                   |
| [`harness/`](harness/README.md) | the `gist-bench` binary — one executable, six modes (`bench` · `verify` · `session` · `certify` · `flagbench` · `sessionprof`), which every lane below drives            |
| `roots.sh`                      | where this package's siblings are — climbs to the package root, then exports `PRODUCT` (this checkout, which builds `gist`), `KINSHIP` (the sibling `relate`), and `REPO` (the corpus envelope) |

`roots.sh` is deliberately per-package rather than shared: it answers "where am
I, and who is next to me," which only a package can answer about itself. The
sibling `irregex` repo carries its own copy for the same reason, and the two
resolve differently on purpose — from here `PRODUCT` is this checkout, because
this is the package that builds the binary every gate below oracles.

`harness/` holds the binary but not the instruments. The 12-class probe
registry, the PMU counters, and the bootstrap/Mann-Whitney verdict math stay
with the engine at `irregex/bench/apparatus/harness/` and arrive here as the
`probes` / `pmu` / `stats` Zig modules through the `irregex` dependency — one
registry and one significance test across both repos, so a race arm here and an
engine rung there are comparable by class name.
