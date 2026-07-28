"""Adverse tests for the differential-fuzz residual ratchet (Layer I).

The ratchet exists because the previous gate had exactly two reachable states:
refuse the mint, or omit the lane. Every test here drives a state that MUST
refuse, because a ratchet nobody has watched fail is indistinguishable from a
constant `return 0` — the certificate would read the same either way.
"""

from pathlib import Path
import json
import tempfile
import unittest

import scanner as report


def _write(directory: str, name: str, payload: dict) -> Path:
    path = Path(directory) / name
    path.write_text(json.dumps(payload))
    return path


def _fuzz(residual: dict[str, int], **over) -> dict:
    """A record shaped like `fuzz.py --json`, with the buckets kept consistent.

    `agree` is the STRICT count (byte-identical stdout and exit code), so it is
    what remains after the declared boundaries, the engine declines, the mutual
    rejections, and the residual are taken out. Deriving it here rather than
    hardcoding it keeps the fixture from asserting 6000/6000 agreement while
    also carrying twenty cases that were not byte-identical.
    """
    declared, declined, both_reject = 17, 0, 3
    total = sum(residual.values())
    return {
        "iterations": 6000,
        "seed": 20260727,
        "corpora": 6,
        "declared": declared,
        "declined": declined,
        "both_reject": both_reject,
        "crashes": 0,
        "agree": 6000 - declared - declined - both_reject - total,
        "residual": residual,
        "residual_total": total,
        **over,
    }


class ResidualRatchetTest(unittest.TestCase):
    """`residual_ratchet` returns a count of hard failures; 0 means mintable."""

    def test_no_baseline_refuses_any_residual(self) -> None:
        """A ratchet must be created deliberately, never defaulted into."""
        self.assertEqual(report.residual_ratchet(_fuzz({"line-count": 1}), None), 1)

    def test_no_baseline_admits_a_clean_run(self) -> None:
        self.assertEqual(report.residual_ratchet(_fuzz({}), None), 0)

    def test_equal_residual_holds(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = _write(tmp, "b.json", _fuzz({"line-count": 4, "line-content": 3}))
            got = _fuzz({"line-count": 4, "line-content": 3})
            self.assertEqual(report.residual_ratchet(got, base), 0)

    def test_grown_class_refuses(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = _write(tmp, "b.json", _fuzz({"line-count": 4}))
            self.assertEqual(report.residual_ratchet(_fuzz({"line-count": 5}), base), 2)

    def test_new_class_refuses_even_when_the_total_shrank(self) -> None:
        """The reason the ratchet is per class and not only on the total.

        A new root cause is news even when the arithmetic improved; keyed on the
        total alone this run would have passed, one class lighter and one
        entirely new defect heavier.
        """
        with tempfile.TemporaryDirectory() as tmp:
            base = _write(tmp, "b.json", _fuzz({"line-count": 9}))
            got = _fuzz({"line-count": 2, "exit-code": 1})
            self.assertLess(got["residual_total"], 9)
            self.assertEqual(report.residual_ratchet(got, base), 1)

    def test_shrink_is_admitted(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = _write(tmp, "b.json", _fuzz({"line-count": 4, "exit-code": 2}))
            self.assertEqual(report.residual_ratchet(_fuzz({"line-count": 1}), base), 0)

    def test_unreadable_baseline_falls_back_to_the_strict_rule(self) -> None:
        """A baseline that cannot be read must not be read as permission."""
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "absent.json"
            self.assertEqual(report.residual_ratchet(_fuzz({"line-count": 1}), missing), 1)

    def test_gist_side_timeouts_and_crashes_are_ratcheted(self) -> None:
        """`divergences` alone would under-report the tail it is supposed to bound."""
        got = _fuzz({"timeout-gist": 2})
        self.assertEqual(got["residual_total"], 2)
        self.assertEqual(report.residual_ratchet(got, None), 1)

    def test_an_oracle_side_timeout_alone_does_not_refuse_the_mint(self) -> None:
        """rg hitting the wall where gist answered is not a gist failure.

        With no baseline the strict rule refuses ANY gist-attributable residual,
        so this asserts the partition itself: a run whose only residual is the
        oracle's own timeout is still mintable.
        """
        self.assertEqual(report.residual_ratchet(_fuzz({"timeout-rg": 2}), None), 0)

    def test_an_oracle_side_class_may_grow_without_refusing(self) -> None:
        """It is load-dependent, so ratcheting it would make the gate flaky."""
        with tempfile.TemporaryDirectory() as tmp:
            base = _write(tmp, "b.json", _fuzz({"line-count": 4, "timeout-rg": 1}))
            got = _fuzz({"line-count": 4, "timeout-rg": 9})
            self.assertEqual(report.residual_ratchet(got, base), 0)

    def test_an_oracle_side_class_is_not_laundered_out_of_the_report(self) -> None:
        """Excluded from the FLOOR is not excluded from the certificate."""
        text = "\n".join(report.fuzz_block(_fuzz({"line-count": 4, "timeout-rg": 2})))
        self.assertIn("`timeout-rg`", text)
        self.assertIn("not** ratcheted", text)
        self.assertIn("6 unresolved", text)

    def test_a_gist_side_class_still_refuses_beside_an_oracle_side_one(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = _write(tmp, "b.json", _fuzz({"timeout-rg": 1}))
            got = _fuzz({"timeout-rg": 1, "line-content": 3})
            self.assertEqual(report.residual_ratchet(got, base), 2)


class FuzzBlockTest(unittest.TestCase):
    def test_residual_classes_are_rendered_with_their_meaning(self) -> None:
        text = "\n".join(report.fuzz_block(_fuzz({"line-count": 4, "timeout-rg": 2})))
        self.assertIn("`line-count`", text)
        self.assertIn("`timeout-rg`", text)
        self.assertIn(report.KLASS_MEANING["line-count"], text)
        self.assertIn("6 unresolved", text)
        self.assertIn("5974/6000", text)

    def test_a_clean_lane_still_reports_itself(self) -> None:
        """The omission this whole change exists to prevent."""
        text = "\n".join(report.fuzz_block(_fuzz({})))
        self.assertIn("differential fuzz", text)
        self.assertIn("0 unresolved", text)
        self.assertIn("5980/6000 = 99.67% are byte-identical", text)

    def test_agreement_is_the_strict_count_not_the_non_divergent_one(self) -> None:
        """The headline may not absorb the boundaries the next sentence explains.

        `iterations - residual` counts the declared boundaries and the mutual
        rejections as agreement, which reads as a higher parity than was
        measured; the record's own `agree` is the byte-identical count.
        """
        text = "\n".join(report.fuzz_block(_fuzz({"line-count": 4})))
        self.assertIn("5976/6000", text)
        self.assertNotIn("5996/6000", text)

    def test_every_class_the_harness_can_emit_has_a_meaning(self) -> None:
        """An unlabeled row in the certificate is a number without a claim.

        The vocabulary has two owners — `fuzz._klass` mints the names and this
        reporter prints their prose — so drift between them is silent by
        construction unless something drives the producer and reads the labels.
        """
        import sys

        sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "conformance" / "rgsuite"))
        import fuzz as harness

        pairs = ((b"x\n", b"x\n"), (b"x\ny\n", b"x\n"), (b"x\n", b"z\n"), (b"x\n", b"x"))
        produced = {harness._klass(0, rc_g, a, b) for rc_g in (0, 2) for a, b in pairs}
        produced |= {"timeout-rg", "timeout-gist", "crash-rg", "crash-gist"}

        self.assertIn("line-content+exit", produced, "the composed form must still be reachable")
        unlabeled = {k for k in produced if report.klass_meaning(k) == "unclassified"}
        self.assertEqual(unlabeled, set())


if __name__ == "__main__":
    unittest.main()
