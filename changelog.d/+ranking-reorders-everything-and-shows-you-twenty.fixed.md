`CLAIM.md` said ranking "reorders the complete verified hit set," full stop —
read next to `--rank`'s documented default of a top-20 view, that is two
different contracts for the same verb, and a reader had to guess which one a
program should rely on. It now says both halves in one place: ranking scores
every file in the complete set (nothing is excluded from the fusion, so
membership never shrinks) and *presents* the bounded top-K by default; the
same complete, unranked set stays one flag away through `-l` or full output,
which ranking never gates.

Separately, three documents restating the mined ripgrep replay's scoreable
total had drifted from each other without anything noticing — two said 411,
one still said 409, and `check_results.py` only ever watched the one README
shaped like `results.json`'s own bucket table, not the sentences elsewhere
that restate the same number in prose. Every restatement (`README.md`,
`TESTING.md`, `CLAIM.md`) now carries an `x-rgsuite-total` marker, and
`tools/evidence_parity.py` — wired into CI beside `check_results.py` — fails
the build the day any marked line disagrees with `results.json` again,
discovered by the marker rather than kept as a list.
