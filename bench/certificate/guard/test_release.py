"""Hermetic tests for the cross-machine release gate (release.py).

Pins the contracts the single-bundle reproducibility check cannot see:
**platform coverage** (a release needs one Mac *and* one Linux certificate),
**bundle discovery** (an explicit ``artifact/<platform>/`` subdir wins over the
flat dir), and that a recorded commit is **provenance, not a requirement** — a
bundle carrying no commit at all is judged exactly like one that does. The
single-bundle validity check is injected, so these cases stay pure — no real
certificate, no git, no benchmark tools.
"""

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import release


def _bundle(
    root: Path, *, os_field: str, commit: str | None = "a" * 40, verdicts=("win", "win")
) -> Path:
    """Write the minimal machine.json + certify_macro.csv a bundle needs here."""
    root.mkdir(parents=True, exist_ok=True)
    meta = {"os": os_field} | ({"git_commit": commit} if commit is not None else {})
    (root / "machine.json").write_text(json.dumps(meta))
    rows = ["class\tpattern\ttool\tmedian_ms\tci_lo_ms\tci_hi_ms\tspeedup_vs_gist\tverdict"]
    for i, verdict in enumerate(verdicts):
        rows.append(f"class{i}\tp\trg\t1.0\t0.9\t1.1\t2.0\t{verdict}")
    (root / "certify_macro.csv").write_text("\n".join(rows) + "\n")
    return root


class PlatformOfTests(unittest.TestCase):
    def test_darwin_and_linux_tokens(self) -> None:
        assert release.platform_of({"os": "Darwin 25.5.0"}) == "darwin"
        assert release.platform_of({"os": "Linux 6.1.0"}) == "linux"

    def test_missing_or_empty_is_none(self) -> None:
        assert release.platform_of(None) is None
        assert release.platform_of({}) is None
        assert release.platform_of({"os": ""}) is None


class DiscoverBundlesTests(unittest.TestCase):
    def test_flat_dir_and_platform_subdir(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _bundle(root, os_field="Darwin 25.5.0")  # flat = Mac
            _bundle(root / "linux-x86_64", os_field="Linux 6.1.0")
            found = release.discover_bundles(root)
            assert found["darwin"] == root
            assert found["linux"] == root / "linux-x86_64"

    def test_explicit_subdir_wins_over_flat_for_same_platform(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _bundle(root, os_field="Darwin 25.5.0")
            _bundle(root / "darwin-arm64", os_field="Darwin 25.5.0")
            found = release.discover_bundles(root)
            assert found["darwin"] == root / "darwin-arm64"


class SpeedsSummaryTests(unittest.TestCase):
    def test_tallies_rg_verdicts(self) -> None:

        with tempfile.TemporaryDirectory() as tmp:
            bundle = _bundle(Path(tmp), os_field="Darwin", verdicts=("win", "win", "loss"))
            summary = release.speeds_summary(bundle)
            assert "2 win / 0 parity / 1 loss" in summary

    def test_missing_csv_is_honest(self) -> None:

        with tempfile.TemporaryDirectory() as tmp:
            assert "unavailable" in release.speeds_summary(Path(tmp))


class VerifyReleaseTests(unittest.TestCase):
    """Coverage + validity, with the single-bundle check injected."""

    PLATFORMS = {"darwin": "Mac", "linux": "Linux"}

    def test_both_present_and_valid_passes(self) -> None:

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _bundle(root, os_field="Darwin 25.5.0")
            _bundle(root / "linux-x86_64", os_field="Linux 6.1.0")
            with mock.patch.object(release, "check_artifacts", return_value=[]):
                ok, rows = release.verify_release(root, platforms=self.PLATFORMS)
            assert ok is True
            assert {r["platform"] for r in rows} == {"darwin", "linux"}
            assert all(r["valid"] for r in rows)

    def test_missing_linux_fails_closed(self) -> None:

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _bundle(root, os_field="Darwin 25.5.0")  # only Mac
            with mock.patch.object(release, "check_artifacts", return_value=[]):
                ok, rows = release.verify_release(root, platforms=self.PLATFORMS)
            assert ok is False
            linux = next(r for r in rows if r["platform"] == "linux")
            assert linux["present"] is False

    def test_invalid_bundle_fails_closed(self) -> None:

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _bundle(root, os_field="Darwin 25.5.0")
            _bundle(root / "linux-x86_64", os_field="Linux 6.1.0")
            with mock.patch.object(
                release, "check_artifacts", return_value=["corpus hash mismatch"]
            ):
                ok, rows = release.verify_release(root, platforms=self.PLATFORMS)
            assert ok is False
            assert all(r["valid"] is False for r in rows)

    def test_bundle_without_a_commit_still_passes(self) -> None:
        """A commit is a reference: its absence must not fail an otherwise-valid mint."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _bundle(root, os_field="Darwin 25.5.0", commit=None)
            _bundle(root / "linux-x86_64", os_field="Linux 6.1.0", commit=None)
            with mock.patch.object(release, "check_artifacts", return_value=[]):
                ok, rows = release.verify_release(root, platforms=self.PLATFORMS)
            assert ok is True
            assert all(r["commit"] == "" for r in rows)

    def test_foreign_commit_is_reported_not_judged(self) -> None:
        """An unrelated SHA is surfaced as provenance, never turned into a verdict."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _bundle(root, os_field="Darwin 25.5.0", commit="f" * 40)
            _bundle(root / "linux-x86_64", os_field="Linux 6.1.0", commit="e" * 40)
            with mock.patch.object(release, "check_artifacts", return_value=[]):
                ok, rows = release.verify_release(root, platforms=self.PLATFORMS)
            assert ok is True
            assert {r["commit"] for r in rows} == {"f" * 40, "e" * 40}


if __name__ == "__main__":
    unittest.main()
