<!--
doc_radar:
  sentinels:
    - file: bench/dominance/partition/gate_partition.py
      contains: ["--committed", "--live", "keep_disabled", "min_walk_agreement"]
    - file: bench/dominance/partition/certify_partition.sh
      contains: ["GIST_NO_KEEP=1", "--type-list --docs", "over-claimed", "rescued"]
    - description: "both populations the lane measures are really built"
      file: bench/dominance/partition/certify_partition.sh
      contains: ["classify tracked", "classify fixture"]
-->

# bench/dominance/partition

The certificate for the **corpus partition** — `--docs` / `--code` / `--data`.

Every other lane in `dominance/` races a rival that answers the same question.
This one cannot: no grep-class tool ships a docs/code axis. ripgrep's type globs
are matched against the basename alone, so a rule like "anything under `docs/`"
is not expressible there at all ([ripgrep#3339](https://github.com/BurntSushi/ripgrep/issues/3339),
open). ugrep's `text` type is five extensions with no code counterpart. zoekt
links go-enry's `Prose`/`Data` classifiers and never calls them.

So the rival is not a flag, it is **what an engineer types instead**: one `-t`
per prose type, hand-assembled, every time.

## The rival is derived, never written down

```
union  =  (rows gist's docs genus is made of)  ∩  (rows rg's registry has)
```

read at run time from `gist --type-list --docs` and `rg --type-list`. Three
things follow, and all three are the point:

- it cannot be strawmanned by leaving a type out;
- it cannot drift when a docs type is added to `genus.zig`;
- it cannot ask rg for a type name rg would exit 2 on.

The types in gist's docs genus that rg has **no name for** are counted and
published too, since they are the part of the question the rival is structurally
unable to ask.

## What it measures

| Arm                  | What it is                                                       |
| -------------------- | ---------------------------------------------------------------- |
| `gist --docs` cold   | fresh process, index armed                                       |
| `gist --docs` warm   | a private resident daemon, **answer keep disabled**              |
| `rg <union>`         | the same question, spelled the way it has to be spelled today    |

`GIST_NO_KEEP=1` on the warm arm is load-bearing. The keep returns byte-identical
rendered stdout for a query already asked against an unchanged corpus, so timing
a repeated query with it armed measures a hash lookup and would publish it as a
search. The daemon here is also **private** (its own `GIST_DIR`, hence its own
socket), so a mint neither disturbs nor is answered by the resident sessions the
coworking agents in this tree keep warm.

## And the half that is not speed

A faster wrong answer is not the claim. Two differences are measured, always over
the **intersection of the two tools' walks**, so what is reported is a
classification difference rather than a walk difference wearing a costume:

- **over-claimed** — files the `-t` union calls prose that gist classifies as
  code. `CMakeLists.txt` is the emblem: rg's `txt` type is `*.txt`, and a
  basename-blind glob cannot tell a build recipe from a note.
- **rescued** — files gist classifies as docs that no rg type name can reach:
  extensionless documents promoted by location or name (`docs/`, `man/`,
  `CHANGELOG`). This is the number that would quietly go to zero if the location
  rule were refactored away.

Both are measured on **two populations**, because they answer different questions:

| Population | What it is                                                                                    | How it's gated |
| ---------- | --------------------------------------------------------------------------------------------- | -------------- |
| `tracked`  | the live repo, what a bare `gist` / `rg` walks                                                 | reported, not floored |
| `fixture`  | a hermetic tree the mint builds, holding exactly the shapes where the two mechanisms must differ | asserted by **equality** |

On the live tree the two rosters very nearly coincide — the rival union is derived
from gist's own docs types, so of course it is. That is honest and worth printing,
but it is not evidence about the mechanism: it says only that the derivation
worked. The claim about *what* a genus knows that a type glob cannot is therefore
proven on the fixture, where the tree is the same on every machine and the counts
can be asserted exactly against `fixture_expected.json` — a written-down
contract, not a captured measurement. Equality is the right relation there,
because an over-claim rising is as much a change of behavior as one falling.

The live tree does carry one floor, and it is the one that makes the columns
beside it mean anything: **walk agreement**, the share of files both tools saw.
If gist and rg stop walking substantially the same corpus, a difference between
their docs sets is a diff of two trees under one heading.

## Files

| Path                     | What                                                              |
| ------------------------ | ----------------------------------------------------------------- |
| `certify_partition.sh`   | the mint: derives the rival, times three arms, builds the fixture, diffs both populations |
| `gate_partition.py`      | fail-closed gate — `--committed` (hermetic) / `--live` (re-mint)   |
| `partition_baseline.json`| the floors: two geomean speedups + the walk-agreement floor       |
| `fixture_expected.json`  | the hand-written contract for the hermetic tree — a change here is a change of behavior |
| `partition_macro.csv`    | published medians per needle — **no ratios**, so a speedup has one source |
| `partition_meta.json`    | the mint's receipts: platform, rival width, and one block per population |

## Running it

```bash
# from package root
bench/dominance/partition/certify_partition.sh          # mint (needs rg + hyperfine)
python3 bench/dominance/partition/gate_partition.py     # assert the published lane
GIST_BENCH=1 python3 bench/dominance/partition/gate_partition.py --live   # re-mint, then assert
```

## What this lane deliberately does not gate

Totality, disjointness, `--no-X` complement, `-t`/`-T` alias parity, and
warm≡cold set equality are **set invariants over the live tree**, and they belong
to `bench/conformance/gates/parity/partition_parity.sh`,
which asserts them without timing anything. A latency lane is the wrong place to
prove a set identity. The mint here still refuses to publish a timing when cold
and warm disagree, so a violation cannot reach these floors in the first place.
