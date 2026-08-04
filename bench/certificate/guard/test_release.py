"""Hermetic tests for the cross-machine release gate (release.py).

VENDORED, BYTE-IDENTICAL across irregex/gist/relate/blast
(`bench/apparatus/SHARED.sha256`, checked by `shared_drift.py`).

Pins the contracts the single-bundle reproducibility check cannot see:
**platform coverage** (a release needs one Mac *and* one Linux certificate),
**bundle discovery** (an explicit ``artifact/<platform>/`` subdir wins over the
flat dir), and that a recorded commit is **provenance, not a requirement** — a
bundle carrying no commit at all is judged exactly like one that does. The
single-bundle validity check is injected, so these cases stay pure — no real
certificate, no git, no benchmark tools.

Because this file is vendored, it asserts on the **mechanism** and never on one
package's numbers: the headline summary is checked by driving whatever
``CHARTER.measure`` returns, not by expecting gist's win/parity/loss tally. A
test that named a specific layer would be red in three of the four packages that
carry it.
"""

import dataclasses
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import release
from profile import CHARTER


def _bundle(root: Path, *, os_field: str, commit: str | None = "a" * 40) -> Path:
    """Write the minimal machine.json + certificate a bundle needs here."""
    root.mkdir(parents=True, exist_ok=True)
    meta = {"os": os_field} | ({"git_commit": commit} if commit is not None else {})
    (root / "machine.json").write_text(json.dumps(meta))
    (root / "CERTIFICATE.md").write_text("# certificate\n")
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
    """The release note renders exactly the headlines this package's charter declares."""

    def _summarize(self, measured: dict[str, float | None]) -> str:
        """Render the release note over a charter whose measurement is `measured`."""
        staged = dataclasses.replace(CHARTER, measure=lambda bundle, text: measured)
        with (
            tempfile.TemporaryDirectory() as tmp,
            mock.patch.object(release, "CHARTER", staged),
        ):
            return release.speeds_summary(_bundle(Path(tmp), os_field="Darwin"))

    def test_renders_every_headline_the_charter_measured(self) -> None:
        if not CHARTER.headlines:
            self.skipTest(f"{CHARTER.package} declares no headline numbers")
        summary = self._summarize(
            {spec.key: float(i + 2) for i, spec in enumerate(CHARTER.headlines)}
        )
        for spec in CHARTER.headlines:
            assert spec.column in summary, f"{spec.column} missing from {summary!r}"

    def test_a_headline_the_mint_did_not_claim_is_omitted_not_zeroed(self) -> None:
        """A number nobody measured must never render as 0 — that reads as a total loss."""
        if not CHARTER.headlines:
            self.skipTest(f"{CHARTER.package} declares no headline numbers")
        absent = CHARTER.headlines[0]
        summary = self._summarize(
            {spec.key: 3.0 for spec in CHARTER.headlines if spec.key != absent.key}
        )
        assert f"0{absent.unit} {absent.column}" not in summary
        assert absent.column not in summary

    def test_missing_certificate_is_honest(self) -> None:

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
