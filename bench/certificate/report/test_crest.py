"""Regression tests for the Crest certificate projection."""

import tempfile
import unittest
from pathlib import Path

import crest as report


class CrestCertificateSpliceTest(unittest.TestCase):
    def test_splice_retires_orphaned_pre_marker_duplicate(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            certificate = Path(temp) / "CERTIFICATE.md"
            certificate.write_text(
                "# Certificate\n\n"
                f"{report.HEADER}\n\nstale\n{report.END}\n\n"
                "## Preserved layer\n\nkeep\n\n"
                f"{report.START}\n{report.HEADER}\n\nold\n{report.END}\n"
            )

            section = f"{report.START}\n{report.HEADER}\n\nfresh\n{report.END}\n"
            report.splice(certificate, section)
            result = certificate.read_text()

        self.assertEqual(result.count(report.HEADER), 1)
        self.assertEqual(result.count(report.START), 1)
        self.assertEqual(result.count(report.END), 1)
        self.assertIn("## Preserved layer\n\nkeep", result)
        self.assertIn("fresh", result)
        self.assertNotIn("stale", result)


if __name__ == "__main__":
    unittest.main()
