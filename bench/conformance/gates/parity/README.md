# bench/conformance/gates/parity

Correctness gates that oracle gist **against `rg`** (or against gist itself) — a
divergence here means the answer is wrong, and each script exits non-zero on any
FN/FP. `scan_regress.sh` sources the shared field registry at
`gist/bench/dominance/races/field.sh`; the
rest are pure gist-side oracles needing no field.

| File                        | Gate                                                                                                                                                                                                                                                                |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `equality.sh`               | **index vs `rg`** — gist ≡ `rg` over a byte-exact corpus snapshot; a file in `rg`'s set but not gist's is a trigram-filter false negative, the reverse is an unsound verify. Both must be zero                                                                      |
| `index_elision_parity.sh`   | **index vs itself** — the auto-indexed run ≡ the same query with `--no-index`, proving the index only elides reads, never changes results                                                                                                                           |
| `line_parity.sh`            | **line reporting** — line numbers / `-n` / column output byte-identical to `rg`                                                                                                                                                                                     |
| `unicode_parity.sh`         | **Unicode drop-in** — `gist <pat>` ≡ `rg <pat>` at rg's default Unicode semantics (fold, classes, `\b`/`-w`, and the `(?-u)` opt-out) over a multi-script fixture, once per engine                                                                                  |
| `patterns_corpus_parity.sh` | **multi-pattern set** — `relate patterns -e …` covers the exact file set `gist -l` answers over, keeping the dragnet/trawl a true drop-in                                                                                                                           |
| `partition_parity.sh`       | **the genus partition over a real tree** — `docs ∪ code ∪ data` is the unfiltered answer and the pairs are disjoint; each `--no-X` is its positive's exact complement; `-t`/`-T` agree with the long flags; index and daemon change speed only; no genus un-hides   |
| `phantom_walk_parity.sh`    | **the `tree.map` snapshot vs itself** — the phantom-served run ≡ the same query with `GIST_NO_PHANTOM=1` (every directory listed live), across both the served and the cost-declined branch, with content-edit and membership-change freshness as the adverse cases |
| `type_union_parity.sh`      | **`-t` is a union** — every type named on the line reaches the answer, built-in or `--type-add`, in any order, byte-identical to `rg`; `-T <custom>` subtracts exactly its positive, and a custom `-t` still respects `.gitignore`                                  |
| `scan_regress.sh`           | **no-prefilter fallback** — the live-tree full-read fallback ≡ `rg (?-u)` (exits 1 on FN/FP) plus a min-of-N speed floor                                                                                                                                            |
| `cover_parity.sh`           | **cold tier, cover plan on vs off** — the wired conjunctive cover changed no answer, against the pre-wiring flat OR, against `--no-index`, and against `rg`                                                                                                        |
| `warm_parity.sh`            | **warm tier ≡ cold tier** — the resident daemon prunes exactly as much as the CLI and no more, against a SECOND daemon with both prunings stood down                                                                                                                |

`cover_parity.sh` and `warm_parity.sh` guard **engine** machinery — the CNF
planner and the crest sieve both ship inside the sibling `irregex` package — but
they live here because they can only be run by the package that builds a `gist`
binary, and `gist` depends on `irregex` rather than the other way round.
Integration evidence belongs downstream of the thing it integrates; the engine's
own standalone proofs stay in `irregex/bench/rungs/sieve/`.

`partition_parity.sh` has no `rg` column on purpose: ripgrep cannot express a
docs/code axis (its type globs are basename-only), so there is no oracle to
borrow and the invariants themselves are the specification. It is the gate that
notices when `--docs` quietly starts returning _most_ of the paper trail — the
classifier unit tests judge spellings, and a tree is where files go missing.

`patterns_corpus_parity.sh` is the one gate here that **constrains its corpus**
rather than building one, because its subject is a population over a real tree.
Everything it needs is a declared knob — the pruned root, the plain root, and
the slate of `<label> <pattern> [<scope>]` cases — so a package measuring itself
fails every one of them, loudly and by design. `bench/apparatus/corpora/`
generates a tree that supplies them all offline, and that is how to see it green:

```bash
bench/apparatus/corpora/fetch.sh torture
(cd .local/gist-corpora/torture && gist index)
GIST_CORPUS_ROOT="$PWD/.local/gist-corpora/torture" GIST_PARITY_SLATE=torture \
  bench/conformance/gates/parity/patterns_corpus_parity.sh
```

`type_union_parity.sh` synthesizes its corpus for the opposite reason
`patterns_corpus_parity.sh` constrains one: its subject is a flag's algebra, not
a population, and it needs go, py, rust, ts and tsx in one tree to ask the
question at all. gist's own checkout is pure Zig, so reading whatever tree it
runs in would make the interesting cases match nothing and pass as vacuously
equal — which is exactly how the bug it guards survived. The mix is the whole
point: built-in types union with built-in types correctly, and a custom type
alone matches `rg` exactly, so only a line holding both diverged.

`phantom_walk_parity.sh` is the differential twin of `index_elision_parity.sh`
with the directory-membership snapshot as the subject instead of the trigram
index, and it guards a claim that is easy to lose: the snapshot may only change
_syscalls_. Both of the walk's branches have to be exercised, because it chooses
between them per directory on cost — a filtered query is served from the mapping
while a broad one declines to the live listing — so the gate pairs `broad-*`
cases against `glob-*` ones. Its freshness cases are the ones that matter most: a
child rewritten in place leaves its parent's clocks untouched, so the directory
stays provably servable while the file is stale, and only per-file freshness
keeps that from becoming a false negative.

```bash
cd <gist-repo-root>
bench/conformance/gates/parity/equality.sh 150 1
bench/conformance/gates/parity/index_elision_parity.sh
bench/conformance/gates/parity/partition_parity.sh
bench/conformance/gates/parity/phantom_walk_parity.sh
bench/conformance/gates/parity/type_union_parity.sh
bench/conformance/gates/parity/unicode_parity.sh
```

---

# The prefilter parity gates — a wired tier may not change an answer

`cover_parity.sh` and `warm_parity.sh` are the adverse guards for the two
prunings the engine added to the query path: the conjunctive cover plan and the
crest sieve. Both are strictly stronger necessary conditions than the flat OR of
extracted literals they front, and strictly stronger means strictly more
elision — so a prefilter that elides one file it should have read is the worst
defect a search tool can ship: silent, total, and indistinguishable from "no
match". These two gates assert the only property that matters, which is that the
answer did not move.

Build the binary once, then run them in dependency order — the cold tier's cover
plan first, then the resident session's copy of it. They stay out of
`zig build test`, which is CI-hermetic and needs only Zig, because these freeze a
multi-thousand-file corpus, index it, and bring up resident daemons. `rg` is
optional (a missing ripgrep drops that arm and keeps the other three); `rsync` is
not, since it is how the corpus gets frozen, so the gate skips rather than
measure a tree ten agents are editing.

```bash
cd <gist-repo-root>
zig build -Doptimize=ReleaseFast
bash bench/conformance/gates/parity/cover_parity.sh
bash bench/conformance/gates/parity/warm_parity.sh   # KEEP=1 leaves the corpus + daemon logs
```

## The warm tier — a daemon may not prune differently than cold

`warm_parity.sh` guards the day the resident session was given the cold tier's
pruning stack. Before it, warm asked the trigram index exactly one question — the
flat OR of the sound prefilter literals — while cold had been asking two stronger
ones for a while. A literal-free class repetition like `[0-9a-f]{8}` forces no
trigram, so the daemon read **100% of the corpus** for it while the CLI beside it
read 6%.

Four arms per case, all of which must produce the same line multiset:

| arm          | what it is                                                 |
| ------------ | ---------------------------------------------------------- |
| `warm`       | the resident daemon with the stack on                      |
| `pre-wiring` | **a second daemon** with `GIST_NO_COVER=1 GIST_NO_CREST=1` |
| `live`       | `gist --no-index` — no index at all, the semantic oracle   |
| `rg`         | ripgrep, so gist's two tiers cannot agree on a shared bug  |

`warm` vs `pre-wiring` isolates the two new prunings on ONE binary, so no build
difference can confound the result; `live` is the transitive proof that warm ≡
cold without either path having to trust a shared index; `rg` is the third-party
check.

**The baseline is a second daemon, and that is load-bearing.** Both stand-down
knobs are read where the pruning is derived — inside the resident session — so
exporting them on a client that gets served warm changes nothing at all, and a
baseline arm spelled that way would silently be a copy of the arm under test.
Two sockets, two sessions, one binary.

### Three ways this gate refuses to pass vacuously

1. **A stack that never fired.** Parity is trivially satisfied by a pruning that
   does nothing, so the gate reads the tier and the admitted document count back
   out of the daemon's own `.index` trace — armed on the daemon, relayed to the
   client over the `diag` frame — and fails if either half narrowed nothing. The
   cover's contribution and the sieve's are attributed **separately**, because a
   pattern like `[0-9a-f]{8}-[0-9a-f]{4}` gets both and crediting its whole prune
   to the sieve would overstate the half being introduced.
2. **A daemon that died mid-run.** A dead daemon and a healthy decline are the
   same `[cold]` string at the client, and cold answers correctly — so every
   later case would keep passing while testing nothing. A death is a hard stop
   naming the case that caused it.
3. **A corpus that moved underneath it.** The corpus is real host source copied
   into a throwaway tree and indexed there. ~10 agents edit this branch
   concurrently and a repo-wide arm takes long enough that two _identical_ runs
   already disagree; freezing the bytes is what lets a difference between arms
   mean something.

The case list is the axis list, not coverage theater — each case exercises a
different stand-down: `-i` stands the cover down but keeps the sieve, `-F` and
`-P` stand both down (a fixed string is not regex source; PCRE2 denotes the
pattern under a foreign grammar), `-v` walks every document so the candidate set
must be a positive superset, and the unprovable patterns (`.*`) must be pruned by
nothing at all.

### What it measured

27 cases byte-identical across all four arms on a frozen 5,883-file corpus. The
cover plan narrowed the index answer on 5 patterns (39-93% of the pre-wiring
candidate set), and the crest sieve narrowed it further on 7 (44-94%) — including
the four the trigram index concedes entirely, where `tier=none` and the sieve is
the _only_ thing pruning. `[0-9a-f]{8}` went from every document to 6% of them.

End-to-end that is **1.4-1.9× geomean** over the ten patterns either half can
prune. It is a range because it is a range: two runs on this laptop reproduced
the candidate columns _exactly_ — same tier, same percentages, every row — and
landed at 1.43× and 1.87×. Both arms are the same client spawn and socket
handshake around a 3-18 ms answer, so a fixed cost sitting in both terms
compresses the ratio toward 1, and how much it compresses depends on what else
the machine is doing. Read the candidate columns as the measure of the two
prunings and the milliseconds as what a caller feels; the gate deliberately
asserts the former and only reports the latter.
