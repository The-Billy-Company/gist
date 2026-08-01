The certificate machinery decides whether a published dominance claim is
well-formed - the mint ledger, the cross-machine release gate, the report
post-processors - and nothing was running its tests. 55 tests across four suites,
all passing, none of them in CI. A break in that subsystem would not have
surfaced until someone tried to mint, which is the worst possible moment to start
debugging it.

So there is a `certificate` job. It runs on a bare checkout with no Zig and no
sibling, and that is worth saying because it is the sort of thing later "fixed"
into something slower: none of these suites build or drive a gist binary. They
are hermetic by construction - every certificate, bundle and residual record is
synthesized into a tmpdir - and their own docstrings say so.

That also means the job does not want the minted artifacts, which matters right
now. The published bundles under `bench/certificate/artifact/` were purged and
gitignored because they had been minted over a corpus that is not public. The
machinery survived that intact and the tests never touched those artifacts, so
this job is the standing proof of the separation rather than something that
quietly needs them back.

Two steps, because they catch different things. The suites are enumerated from a
glob rather than listed, for the same reason the formatter's file set is. Then
every module gets imported, which earns its place: `test_release` already reaches
`release` → `artifacts` → `layers` transitively, but nothing reaches `ratio.py`
or the nine report post-processors, so a bad import in one of those was
invisible. I proved both halves by injecting defects - breaking the ledger's
column-alignment contract (`c.ljust(w)` → `c`) fails the suite step with
`FAILED (failures=1)`, and appending a bad import to `ratio.py` or
`report/portable.py` sails past the suites at exit 0 and is caught only by the
import step. Both revert clean.

One caveat for whoever reads a future red X: `report/test_scanner_residual.py`
puts `bench/conformance/rgsuite/` on `sys.path` and drives `fuzz._klass`, to prove
every residual class the harness can emit has prose in the reporter. The coupling
is the test's entire point, since that vocabulary has two owners and drift
between them is otherwise silent, but it does mean a change to the fuzz harness
can fail this job. Reconcile the two; do not drop the suite from the glob.
