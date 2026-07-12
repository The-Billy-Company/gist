# Committed race data (figure source)

Reproducible snapshots of the three `bench/races/*.sh` races, published from the
gitignored `.local/gist-compete/*.csv`. The `gist_{cold_field,warm_dominance,regex_matrix}.py`
dataviz figures read these at render time — generated from committed data, not
transcribed. `check_artifacts.py --dataviz` enforces that.

| File | Race | Columns |
|---|---|---|
| `cold.csv` | `coldquery.sh` — cold one-shot literal | `needle,tool,kind,ms,gist_ms,ratio` |
| `warm.csv` | `headtohead.sh` — warm resident vs unindexed | `needle,tool,ms,gist_ms,ratio` |
| `regex.csv` | `regex_headtohead.sh` — cold regex tiers | `tier,pattern,tool,kind,ms,gist_ms,ratio` |
| `scan_progression.json` | curated PMU / optimization history (not a race — see its `provenance`) | — |

**Machine-specific** (Apple M2, ~15.3k-file worktree, `ratio = rival_ms / gist_ms`;
`>1` = gist faster). The verdicts on this box: gist's **WARM resident** path
dominates (rg 807×, git grep 1158×, 20/20), while its **COLD** CLI loses to the
whole field (rg 0.3×, csearch/zoekt 0.1×) — the per-query freshness `stat()`-walk
cost — consistent with the macro certificate in `bench/certify/artifact/`.
Regenerate (`make figures`) rather than hand-editing.
