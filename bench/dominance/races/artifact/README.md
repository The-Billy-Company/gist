# Committed race data (figure source)

Reproducible snapshots for the **three figure-backed** races
(`coldquery` · `headtohead` · `regex_headtohead`), published from the gitignored
`.local/gist-compete/*.csv`. The sibling scripts `pcre_headtohead.sh`,
`searchzip_headtohead.sh`, and `relate_headtohead.sh` race live but do not ship
CSVs here — no dataviz figure consumes them yet. The
`gist_{cold_field,warm_dominance,regex_matrix}.py` figures read these files at
render time — generated from committed data, not transcribed.
`check_artifacts.py --dataviz` enforces that.

| File                    | Race                                                                   | Columns                                   |
| ----------------------- | ---------------------------------------------------------------------- | ----------------------------------------- |
| `cold.csv`              | `coldquery.sh` — cold one-shot literal                                 | `needle,tool,kind,ms,gist_ms,ratio`       |
| `warm.csv`              | `headtohead.sh` — warm resident vs unindexed                           | `needle,tool,ms,gist_ms,ratio`            |
| `regex.csv`             | `regex_headtohead.sh` — cold regex tiers                               | `tier,pattern,tool,kind,ms,gist_ms,ratio` |
| `scan_progression.json` | curated PMU / optimization history (not a race — see its `provenance`) | —                                         |

**Machine-specific** (Apple M2, ~15.3k-file worktree, `ratio = rival_ms / gist_ms`;
`>1` = gist faster). The verdicts on this box: gist's **WARM resident** path
dominates (rg 807×, git grep 1158×, 20/20), while its **COLD** CLI loses to the
whole field (rg 0.3×, csearch/zoekt 0.1×) — the per-query freshness `stat()`-walk
cost — consistent with the macro certificate in `bench/certificate/artifact/`.
Regenerate (`make figures`) rather than hand-editing.

**Do not read `cold.csv` as gist's verdict against the indexed pair.** `warm.csv`
holds only the unindexed scanners, so csearch and zoekt appear in _this_ directory
exclusively at gist's worst face: a fresh process paying a full freshness proof,
against two rivals answering from an index with no freshness obligation at all —
a weaker question, and one they answer while going silently stale. The comparison
in gist's actual resident configuration lives in the certificate's warm tier
(`certify_warm.csv`, columns `csearch_ms` / `zoekt_ms`), where the same `pgxpool`
needle that loses here is **3.81 ms vs csearch 41.37 ms and zoekt 68.61 ms**. Both
faces are real; neither alone is the story.
