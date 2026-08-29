- New conformance lane, `bench/conformance/rgsuite/records.py`, over the two
  surfaces a mined ripgrep suite structurally cannot reach: the by-value escape
  family (rg *rejects* `\N{NAME}` and every octal spelling, so its own tests hold
  no case for them) and the `--null-data` record model (rg's tests hold no record
  with an interior newline, so they never ask what `^` means inside one). 1533
  cells of pattern × output-frame × fixture, with ripgrep the oracle for every
  cell it can answer and Python `re` the referee — over records split by hand —
  for the cells where the two tools disagree about the language rather than the
  layout.

  1237 cells are byte-identical, 21 are refused by both, and 275 sit at one of
  five declared boundaries, each a predicate that RE-PROVES its own mechanism on
  every run rather than a pattern forgiven by name: rg reading `^` as "after a
  `\n`", so a record's own start is not a line start to it; rg keeping the NUL in
  the slice it searches, so `\z` matches nothing; rg counting its own "binary file
  matches" notice as a line; rg emitting a `--vimgrep` row missing the column its
  own format defines; and the spellings rg cannot compile, where gist's answer is
  held to `re`'s instead. A family that stops reproducing its mechanism stops
  being excused.

  Zero unjustified divergences, and every family's population is pinned by exact
  count in `records_baseline.json` — so a boundary that grows OR shrinks fails the
  lane, and if ripgrep fixes one the answer is to delete the family rather than
  refresh the number. Wired into `ci_order.sh` ahead of the perf phase. It earned
  its keep on the first run, by finding the byte-mode bug above.
