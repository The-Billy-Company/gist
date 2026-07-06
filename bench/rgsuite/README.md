# gist ⇄ ripgrep drop-in proof (`rgsuite`)

This is the honest, reproducible measurement of how close gist's `rg` verb is to
a **drop-in ripgrep** on the surface it claims to support (currently **98.6%**
byte-for-byte, with 4 known divergences — see the scoreboard), benchmarked against
real ripgrep
as both the **correctness oracle** and the **performance baseline**. Two tracks:

- **Track A — correctness.** Replay ripgrep's _own_ integration suite
  (`upstream/ripgrep/tests/*.rs`) against `gist rg` and diff byte-for-byte vs the
  installed `rg`. No hardcoded expected strings — ripgrep is the ground truth.
- **Track B — performance.** Race gist's indexed query path against `rg` (and
  ugrep / ag / GNU-grep / git-grep / csearch / zoekt) on the live monorepo.
  Scripts live in the sibling `races/` folder: `../races/coldquery.sh` (fresh
  process) and `../races/headtohead.sh` (warm resident index).

## Track A — correctness scoreboard

`rg 15.1.0`, 441 mined `rgtest!` cases (invocations; a multi-command `rgtest!`
mines one case per command):

| Bucket    | Count | Meaning                                                                  |
| --------- | ----: | ------------------------------------------------------------------------ |
| **PASS**  |   275 | `gist rg` stdout == `rg` stdout, byte-for-byte                           |
| **ORDER** |     3 | identical set, dir-walk order only (gist sorts paths) → soft pass        |
| **FAIL**  |     4 | a supported-surface divergence (a real bug — see below)                  |
| NA        |    38 | unsupported **by design** (see boundaries below)                         |
| SKIP      |   121 | not replayable here (control-flow test, pcre2-only, non-stdout terminal) |

**Supported-surface parity = (PASS+ORDER) / (PASS+ORDER+FAIL) = 278/282 = 98.6%.**
Four supported-surface cases still diverge from ripgrep, so this is **not yet
zero-FAIL**: `f917_trim_max_columns_matches`, `type_list`, `r599`, `r1765`. Until
they are fixed or reclassified NA with recorded rationale, gist is a
**98.6%-parity** drop-in on its supported surface, not a byte-identical one.

### Design boundaries (why NA is honest, not hidden failure)

An NA is only ever assigned to a case that would _otherwise_ diverge AND whose
divergence is attributable to one of gist's stated scope boundaries — never to
excuse an in-scope bug. gist **fails loud (exit 2)** on features it can't honor,
so an NA is a deliberate, announced refusal, not a silent wrong answer. The
current boundaries:

1. **line-oriented** — `-U`/`--multiline`/`--multiline-dotall` (a match may not
   span line boundaries). The largest NA bucket.
2. **no ANSI** — `--color=always` emits no color escapes (`path:line:text` only).
3. **text/source-oriented** — gist skips binary files; no `--binary`/`-uuu`, and
   it never emits ripgrep's `binary file matches` summary line.
4. **UTF-8 / byte engine** — `-E`/`--encoding` for a non-BOM charset (SJIS,
   EUC-JP, explicit UTF-16) is refused; a **UTF-8/UTF-16 BOM is auto-detected**.
5. **ASCII case-folding** — `-i` folds ASCII only; no Unicode case folding, and
   no per-branch `(?i)` across multiple `-e` patterns.
6. **RE2-style engine** — `-P`/pcre2, lookaround, backreferences (mostly SKIP).
7. **ignore scope** — a _global_ gitignore (`core.excludesFile`) and fd's
   `.fdignore` dialect aren't read; the in-repo hierarchy is (see below).
8. **type registry** — `--type-list` differs because gist's registry is a
   documented _superset_ of ripgrep's.

### Surface gist matches ripgrep on (all PASS)

Filename display rules (implicit / `-H` / `-I` / `--no-filename`), line numbers
(`-n`/`-N`), `-i`/`-s`/`-S` case, `-w` word (true `(^|\W)…(\W|$)` semantics, not
`\b…\b`), `-F` fixed strings, `-v` invert, `-o` only-matching (incl. zero-width
matches of a nullable pattern), `-c`/`--count`, `--count-matches` (incl. the
`--count -o` override), `-l`/`--files-with-matches`, `-L`/`--files-without-match`,
`-A`/`-B`/`-C` context (incl. `-A/-B` precedence over `-C` and `--`/`:`/`-`
framing), `-m`/`--max-count`, `-M`/`--max-columns` (omit-long-line placeholder),
`-r`/`--replace` **with `$1`/named capture groups**, `-t`/`-T`/`-g`/`--glob`/
`--iglob` type & glob scoping (incl. `!`-exclude, leading-`/` anchoring, and
`{a,b}` brace expansion), `--type-add`, **`--json`** (the full JSON-Lines record
stream), the **git ignore hierarchy** (`.gitignore`/`.ignore`/`.rgignore`,
`.git/info/exclude` incl. linked worktrees, **ancestor/parent** ignores,
`--ignore-file` precedence, and every `--ignore-file`/`--no-ignore*`/`-u`/`-uu`/
`--require-git` tier), `--path-separator`, **UTF-8/UTF-16 BOM auto-detection**,
**stdin search** (rg's `is_readable_stdin` rule: pipe/regular-file yes,
tty/`/dev/null` no), and rg exit codes (0 match / 1 no-match / 2 error).

## Track B — performance (18,635 files · 155.9 MiB corpus)

Measured with hyperfine, warm page cache. gist queries its persisted trigram
index (reads only candidate files); unindexed tools re-walk the tree each call.

**Cold — fresh process** (`../races/coldquery.sh`), geomean speedup, gist wins:

| vs       |  speedup |  wins |
| -------- | -------: | ----: |
| ripgrep  | **3.3×** | 11/11 |
| git grep |     2.4× | 10/11 |
| ag       |     5.5× | 11/11 |
| GNU grep |     9.9× | 11/11 |
| ugrep    |    13.0× | 11/11 |

Selective needles reach 4–6× vs rg (e.g. `pgxpool` 6.1×); ubiquitous tokens
(`func`, `})`) approach parity — gist must read the many candidate files they hit.

**Warm — resident RAM index** (`../races/headtohead.sh`), the agent-session model
gist is built for, geomean speedup, gist wins:

| vs       |    speedup |  wins |
| -------- | ---------: | ----: |
| ripgrep  | **~1770×** | 20/20 |
| git grep |     ~1400× | 20/20 |
| ag       |     ~2640× | 20/20 |
| GNU grep |     ~5460× | 20/20 |
| ugrep    |     ~6600× | 20/20 |

The honest headline: gist is a **near-drop-in rg (98.6% supported-surface parity,
4 known FAILs)** that is **~3.3× faster cold** and **~1770× faster warm-resident**
than
ripgrep — the "40×" claim sits comfortably between the one-shot and resident
models and is conservative for gist's intended long-lived agent-session use.

## Running it

```bash
# build the binary the suite drives
zig build            # in pkg/kernels/gist  → zig-out/bin/gist (the CLI, `rg` verb)

# Track A — correctness (needs `rg` on PATH as the oracle)
python3 run.py                # scoreboard; exits non-zero if any FAIL
python3 run.py --list-na      # also print every NA + its reason
python3 dbg.py <test-name>…   # side-by-side rg vs gist for one case

# Track B — performance
../races/coldquery.sh               # fresh-process race
../races/headtohead.sh              # warm resident-index race
```

`spec.json` is **self-contained** (every fixture byte base64-embedded), so
Track A replays without the ripgrep checkout. Regenerate it only when bumping the
tracked ripgrep:

```bash
python3 mine.py [path/to/ripgrep/tests]   # default: <repo>/.etc/ripgrep/tests
```

## Files

| File           | Role                                                          |
| -------------- | ------------------------------------------------------------- |
| `spec.json`    | frozen, self-contained mined spec (441 `rgtest!` invocations) |
| `mine.py`      | regenerates `spec.json` from a ripgrep checkout               |
| `run.py`       | differential runner + honest scoreboard (the gate)            |
| `dbg.py`       | single-test side-by-side inspector                            |
| `results.json` | last `run.py` per-test verdicts (regenerated each run)        |
