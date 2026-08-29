- `--null-data` treats a record as what it is: NUL-delimited, and free to hold
  newlines. So `^` and `$` are newline assertions inside one, `\z` is the record's
  real end, and a record's trailing newline is content rather than a terminator —
  it opens the empty line after it like any other. Previously `^zz` missed a `zz`
  sitting after an interior newline.

  Python's `re` refereed it rather than us: split a file on NUL by hand, hand each
  record to `re` with `re.MULTILINE`, and compare. Over 322 cells of record-mode
  `-c` and `-o` answers gist now agrees on every one, and ripgrep disagrees on 13
  — it misses a record's own start for `^` (reading `^` as "after a `\n`", so a
  record beginning after a NUL is not a line start to it), prints whole records as
  `-o` rows for matches it rejected, and matches nothing at all for `\z`, whose
  NUL it keeps in the slice it searches. BSD `grep -z` agrees with gist about `^`.

  It is also the faster reading. A record is a *sequence of lines* whenever the
  pattern cannot see across one, so gist splits at the newlines and every piece
  goes down the ordinary per-line ladder with its DFA, prefilter, and SIMD kernels
  intact, instead of the whole-record Pike scan an assertion-bearing wide haystack
  otherwise forces. On 50 MB of records, against a build with that one switch
  forced off, `^\w+ mid` went from 341.9 ms wall / 2885 ms CPU to 16.2 / 50 — 21×
  wall and 57× CPU — while the rows a required literal already carried moved by
  under 1%. Against ripgrep the record-mode slate is now 4.2–6.2× faster on wall
  clock *and* 1.3–5.0× on CPU; the alternation used to win on wall clock only by
  spending 5× rg's CPU to do it.
