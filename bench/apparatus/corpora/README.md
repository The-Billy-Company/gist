# gist/bench/corpora — the multi-corpus battery

Every other harness in `bench/` measures **one corpus** (a large host monorepo)
on one machine. This folder makes the correctness claim portable: it installs
five trees with radically different shapes under `.local/gist-corpora/`
(machine-local, gitignored) and replays a differential flag/pattern slate on
each — `gist rg` vs real ripgrep, byte-for-byte, both engines.

| Corpus       | Shape it exercises                                                                                              |
| ------------ | --------------------------------------------------------------------------------------------------------------- |
| `linux`      | C at scale — ~90k files, deep dirs, huge generated headers (pinned `v6.10`)                                     |
| `cpython`    | Python + C — `Lib/test` ships deliberately broken encodings and odd filenames (pinned `v3.13.0`)                |
| `typescript` | Both file-size extremes in one tree — `checker.ts` ~3 MiB beside ~60k tiny baseline fixtures (pinned `v5.8.3`)  |
| `subtitles`  | ripgrep's own perf corpus — one giant line-oriented text file per language (en+ru, fixed 256 MiB prefixes)      |
| `torture`    | Generated adversarial tree (`torture.py`, deterministic) — cap edges, symlink cycles, NULs, UTF-16, CRLF, links |

`torture` has a second job. Its `vendor/` and `src/` subtrees exist for
`gates/parity/patterns_corpus_parity.sh`, which needs one corpus property it
cannot manufacture for itself: a directory `haystack.isSkipDir` prunes out of
the corpus loader that the rg-parity walk still **enters**. `vendor/` is in the
comptime skip set and nothing here is gitignored, so the two populations can
actually disagree — which is the whole instrument. (`node_modules` prunes the
same way but is gitignored in nearly every real tree, and then both sides drop
it and the gate passes having proved nothing.) That gate's `torture` slate names
`hexdrift` / `hexdrift_encode` / `ledger_entry` / `LedgerEntry` / `cfg`
directly, so a rename in either place has to land in both; the sentinel above is
the only thing watching.

```bash
bench/apparatus/corpora/fetch.sh torture
(cd .local/gist-corpora/torture && gist index)     # so the gate's armed leg is armed
GIST_CORPUS_ROOT="$PWD/.local/gist-corpora/torture" GIST_PARITY_SLATE=torture \
  bench/conformance/gates/parity/patterns_corpus_parity.sh
```

## Run it

```bash
bench/corpora/fetch.sh                   # install all five (idempotent; [name…] to scope)
python3 bench/corpora/sweep.py           # every installed corpus × both engines
python3 bench/corpora/sweep.py --corpora torture --engine serial
python3 bench/corpora/sweep.py --list    # print the case slate
```

The fetcher is pinned (exact tags, fixed decompressed byte-counts) so two
machines build byte-identical corpora; a corpus that already exists is
verified and skipped. The sweep writes per-case records to
`.local/gist-corpora/sweep-results.json`.

## The contract

ripgrep is the **oracle** — the sweep hardcodes no expected strings. Each case
runs identical argv in the corpus root and requires exit-code parity plus
stdout parity (byte-exact where the argv makes rg deterministic, sorted-line
equality for unsorted walks). JSON cases are compared after normalizing only
rg's wall-clock/printer-internal fields (`elapsed`, `bytes_printed`), exactly
as `rgsuite` does. The whole slate runs once per engine (parallel
`GIST_NO_PARALLEL=` unset, serial `GIST_NO_PARALLEL=1`) because the two share
flags but not code paths.

Divergences this battery has already caught and rooted out: JSON base64
`bytes` encoding for invalid UTF-8, `--crlf` terminator parity across every
output form, rg's implicit-path "No files were searched" exit-2 heuristic,
dangling-symlink and symlink-loop reporting under `-L`, Unicode-aware `-w`
word boundaries, `-M` terminator-inclusive width, rg's full binary model —
the line-buffer **committed-prefix** geometry (a 3-byte BOM-sniff first read,
per-fill commit at the last newline, the NUL-bearing fill discarded whole),
the `-U` slice-vs-line routing keyed on whether the pattern can actually
match `\n` (rg's `multi_line_with_matcher`), explicit-file convert semantics
with printer-side line suppression, and the byte-count clamps in
`--json`/`--stats` — and an uninitialized generation array in the capture VM
that made `-r` replacement nondeterministic under ReleaseFast.
