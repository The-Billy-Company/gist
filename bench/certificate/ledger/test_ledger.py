"""Hermetic tests for the certificate mint ledger (ledger.py).

VENDORED, BYTE-IDENTICAL across irregex/gist/relate/blast
(`bench/apparatus/SHARED.sha256`, checked by `shared_drift.py`).

Pins the four contracts the ledger exists to hold: a **dropped layer is loud**
(the regression that used to surface far away as a documentation failure), a
**moved headline is named with both sides** so a silent regression cannot hide
behind a re-mint, a **commit is provenance** that can be absent without
consequence, and the rendered table lands column-aligned so a mint never leaves
the tree formatter-dirty. Every certificate here is synthesized — no real
bundle, no git, no benchmark tools.

Because this file is vendored, every case is driven from the package's own
charter rather than from any one package's layers: the fixture builds its
headers from the roster and the drop test removes whichever layer the roster
happens to end with. How a specific headline is *scraped* is a per-package
contract and is tested next to that package's `guard/profile.py`.
"""

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

import ledger

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "guard"))
from profile import CHARTER  # noqa: E402

#: Any rostered layer will do for the drop test — what is under test is that a
#: gap is reported, not which layer left. Taking the last one keeps the fixture
#: honest when a package rosters only one.
DROPPABLE = tuple(ledger.LAYERS)[-1]


def _certificate(
    *,
    layers: tuple[str, ...] = tuple(ledger.LAYERS),
    files: int = 20435,
    mib: float = 199.9,
    body: str = "",
) -> str:
    """Synthesize a certificate carrying exactly ``layers``.

    Headers come from the roster itself, so the fixture tracks the contract
    instead of duplicating it: adding a layer to the charter widens these tests.
    ``body`` appends package-specific prose for a caller that needs a headline to
    be scrapeable; the generic cases never do.
    """
    out = ["# Dominance-and-Fit Certificate", "", f"corpus: **{files}** files · {mib} MiB", ""]
    for name in layers:
        out += [f"## {ledger.LAYERS[name]} — section", ""]
    return "\n".join(out) + "\n" + body


def _bundle(root: Path, *, text: str | None = None, machine: dict[str, object] | None = None):
    """Write a certificate bundle; ``machine=None`` means no machine.json at all."""
    root.mkdir(parents=True, exist_ok=True)
    (root / ledger.CERTIFICATE).write_text(_certificate() if text is None else text)
    if machine is not None:
        (root / "machine.json").write_text(json.dumps(machine))
    return root


class ReadMintTests(unittest.TestCase):
    def test_a_complete_mint_carries_every_roster_layer(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            mint = ledger.read_mint(_bundle(Path(tmp), machine={"os": "Darwin 25.5.0"}))
            assert mint is not None
            assert mint.layers == tuple(ledger.LAYERS)
            assert mint.absent == ()
            assert (mint.corpus_files, mint.corpus_mib) == (20435, 199.9)
            assert mint.platform == "darwin"

    def test_a_headline_the_certificate_does_not_state_records_none_not_zero(self) -> None:
        """A bare roster carries no numbers; recording 0 would read as a total loss."""
        if not CHARTER.headlines:
            self.skipTest(f"{CHARTER.package} declares no headline numbers")
        with tempfile.TemporaryDirectory() as tmp:
            mint = ledger.read_mint(_bundle(Path(tmp)))
            assert mint is not None
            assert all(mint.headline(h.key) is None for h in CHARTER.headlines)

    def test_a_dropped_layer_is_recorded_as_absent(self) -> None:
        """The regression this ledger exists to catch: the numbers improve, one layer vanishes."""
        kept = tuple(n for n in ledger.LAYERS if n != DROPPABLE)
        with tempfile.TemporaryDirectory() as tmp:
            mint = ledger.read_mint(_bundle(Path(tmp), text=_certificate(layers=kept)))
            assert mint is not None
            assert mint.absent == (DROPPABLE,)
            assert DROPPABLE not in mint.layers

    def test_a_missing_certificate_is_none_not_an_exception(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            assert ledger.read_mint(Path(tmp)) is None

    def test_the_digest_keys_the_content_so_a_re_mint_cannot_hide(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = ledger.read_mint(_bundle(root / "a", text=_certificate()))
            same = ledger.read_mint(_bundle(root / "b", text=_certificate()))
            moved = ledger.read_mint(_bundle(root / "c", text=_certificate(files=20436)))
            assert first is not None and same is not None and moved is not None
            assert first.digest == same.digest
            assert moved.digest != first.digest


class CommitIsProvenanceTests(unittest.TestCase):
    """A commit is a reference field — never resolved, compared, or required."""

    def test_a_bundle_with_no_machine_json_still_records(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            mint = ledger.read_mint(_bundle(Path(tmp)))
            assert mint is not None
            assert mint.commit is None
            assert mint.platform == "unknown"
            assert mint.layers == tuple(ledger.LAYERS)  # the measurement still counts

    def test_a_machine_json_without_a_commit_still_records(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            mint = ledger.read_mint(_bundle(Path(tmp), machine={"os": "Linux 6.1.0"}))
            assert mint is not None
            assert mint.commit is None
            assert mint.platform == "linux"

    def test_an_unparseable_machine_json_degrades_instead_of_failing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bundle = _bundle(Path(tmp))
            (bundle / "machine.json").write_text("{not json")
            mint = ledger.read_mint(bundle)
            assert mint is not None
            assert mint.platform == "unknown"


class DeltaTests(unittest.TestCase):
    #: A baseline value per headline, distinct so a swapped key is visible.
    BASELINE = {spec.key: float(i + 2) for i, spec in enumerate(CHARTER.headlines)}

    def _mint(self, **over) -> ledger.Mint:
        base = dict(
            recorded="2026-07-24T00:00:00Z",
            platform="darwin",
            machine="m",
            bundle="b",
            digest="d" * 64,
            corpus_files=20435,
            layers=tuple(ledger.LAYERS),
            absent=(),
            headlines=dict(self.BASELINE),
        )
        return ledger.Mint(**(base | over))

    def test_a_dropped_layer_shouts(self) -> None:
        kept = tuple(n for n in ledger.LAYERS if n != DROPPABLE)
        changes = ledger.delta(self._mint(layers=kept, absent=(DROPPABLE,)), self._mint())
        assert any(f"LAYERS DROPPED: {DROPPABLE}" in c for c in changes)

    def test_a_regained_layer_is_reported_calmly(self) -> None:
        kept = tuple(n for n in ledger.LAYERS if n != DROPPABLE)
        changes = ledger.delta(self._mint(), self._mint(layers=kept, absent=(DROPPABLE,)))
        assert any(f"layers added: {DROPPABLE}" in c for c in changes)
        assert not any("DROPPED" in c for c in changes)

    def test_moved_numbers_are_named_with_both_sides(self) -> None:
        if not CHARTER.headlines:
            self.skipTest(f"{CHARTER.package} declares no headline numbers")
        spec = CHARTER.headlines[0]
        was = self.BASELINE[spec.key]
        moved = self._mint(
            corpus_files=20400, headlines=dict(self.BASELINE) | {spec.key: was + 1.0}
        )
        changes = ledger.delta(moved, self._mint())
        assert any(f"{spec.column} " in c and f"{was:g} -> {was + 1:g}" in c for c in changes)
        assert "corpus 20435 -> 20400 files" in changes

    def test_a_direction_is_reported_as_improvement_or_regression_not_a_bare_delta(self) -> None:
        """A number moving the wrong way must SAY so — a bare arrow reads as neutral."""
        if not CHARTER.headlines:
            self.skipTest(f"{CHARTER.package} declares no headline numbers")
        spec = CHARTER.headlines[0]
        worse = self.BASELINE[spec.key] + (-1.0 if spec.rising else 1.0)
        changes = ledger.delta(
            self._mint(headlines=dict(self.BASELINE) | {spec.key: worse}), self._mint()
        )
        assert any("REGRESSED" in c for c in changes), changes

    def test_a_headline_that_stopped_being_claimed_is_not_a_regression_to_zero(self) -> None:
        """Dropping a claim and losing at it are different events with different fixes."""
        if not CHARTER.headlines:
            self.skipTest(f"{CHARTER.package} declares no headline numbers")
        spec = CHARTER.headlines[0]
        gone = {k: v for k, v in self.BASELINE.items() if k != spec.key}
        changes = ledger.delta(self._mint(headlines=gone), self._mint())
        assert any("NO LONGER CLAIMED" in c for c in changes), changes

    def test_the_first_mint_is_not_a_regression(self) -> None:
        assert ledger.delta(self._mint(), None) == ["first recorded mint for this platform"]

    def test_an_identical_headline_still_reports_the_content_change(self) -> None:
        """Two different digests with equal numbers must not render as an empty delta."""
        assert ledger.delta(self._mint(), self._mint()) == [
            "content changed, headline numbers identical"
        ]


class StoreTests(unittest.TestCase):
    """Round-trip + the fail-closed survey, against a temporary ledger."""

    def _store(self, tmp: Path):
        return mock.patch.multiple(ledger, LEDGER=tmp / "ledger.jsonl", RENDER=tmp / "LEDGER.md")

    def test_round_trip_preserves_layer_tuples_and_time_order(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self._store(root):
                newer = DeltaTests()._mint(recorded="2026-07-24T12:00:00Z", digest="a" * 64)
                older = DeltaTests()._mint(recorded="2026-07-20T12:00:00Z", digest="b" * 64)
                ledger.save([newer, older])
                back = ledger.load()
            assert [m.digest for m in back] == ["b" * 64, "a" * 64]
            assert back[0].layers == tuple(ledger.LAYERS)
            assert isinstance(back[0].layers, tuple)

    def test_an_unrecorded_certificate_is_surfaced_with_its_delta(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self._store(root):
                _bundle(root / "artifact", machine={"os": "Darwin 25.5.0"})
                report = ledger.survey(root / "artifact")
            assert len(report) == 1
            assert report[0]["recorded"] is False
            assert report[0]["changes"] == ["first recorded mint for this platform"]

    def test_a_recorded_certificate_reads_clean(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self._store(root):
                bundle = _bundle(root / "artifact", machine={"os": "Darwin 25.5.0"})
                mint = ledger.read_mint(bundle)
                assert mint is not None
                ledger.save([mint])
                report = ledger.survey(root / "artifact")
            assert report[0]["recorded"] is True
            assert report[0]["changes"] == []
            assert report[0]["absent_layers"] == []


class VerifyExitTests(unittest.TestCase):
    """`verify` must fail only on what the fix it prints can actually clear."""

    def _run(self, tmp: Path, argv: list[str], *, layers: tuple[str, ...], record: bool) -> int:
        root = tmp / "artifact"
        _bundle(root, text=_certificate(layers=layers), machine={"os": "Darwin 25.5.0"})
        with (
            mock.patch.multiple(ledger, LEDGER=tmp / "ledger.jsonl", RENDER=tmp / "LEDGER.md"),
            redirect_stdout(io.StringIO()),
            redirect_stderr(io.StringIO()),
        ):
            if record:
                mint = ledger.read_mint(root)
                assert mint is not None
                ledger.save([mint])
            return ledger.main(["--artifacts-root", str(root), *argv])

    def test_an_unrecorded_mint_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code = self._run(Path(tmp), ["verify"], layers=tuple(ledger.LAYERS), record=False)
        assert code == 1

    def test_a_recorded_complete_mint_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code = self._run(Path(tmp), ["verify"], layers=tuple(ledger.LAYERS), record=True)
        assert code == 0

    def test_a_recorded_but_incomplete_mint_passes_by_default(self) -> None:
        """`record` already cleared the drift; a layer gap has a different owner and remedy."""
        kept = tuple(n for n in ledger.LAYERS if n != DROPPABLE)
        with tempfile.TemporaryDirectory() as tmp:
            code = self._run(Path(tmp), ["verify"], layers=kept, record=True)
        assert code == 0

    def test_the_same_incomplete_mint_fails_when_completeness_is_demanded(self) -> None:
        kept = tuple(n for n in ledger.LAYERS if n != DROPPABLE)
        with tempfile.TemporaryDirectory() as tmp:
            code = self._run(Path(tmp), ["verify", "--require-layers"], layers=kept, record=True)
        assert code == 1

    def test_status_never_fails_on_either_condition(self) -> None:
        kept = tuple(n for n in ledger.LAYERS if n != DROPPABLE)
        with tempfile.TemporaryDirectory() as tmp:
            code = self._run(Path(tmp), ["status"], layers=kept, record=False)
        assert code == 0

    def test_an_empty_root_fails_rather_than_passing_vacuously(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with (
                mock.patch.multiple(
                    ledger, LEDGER=root / "ledger.jsonl", RENDER=root / "LEDGER.md"
                ),
                redirect_stdout(io.StringIO()),
                redirect_stderr(io.StringIO()),
            ):
                code = ledger.main(["--artifacts-root", str(root / "nothing"), "verify"])
        assert code == 1


class RenderTests(unittest.TestCase):
    def test_the_table_is_column_aligned_so_the_tree_stays_formatter_clean(self) -> None:
        """LEDGER.md is regenerated on every mint — unaligned output would re-dirty it."""
        lines = ledger._table(["a", "bbbb"], [["cccccc", "d"], ["e", "ffffffff"]])
        assert len({len(line) for line in lines}) == 1
        assert set(lines[1]) <= {"|", "-", " "}

    def test_an_empty_ledger_renders_without_a_headless_table(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            render = Path(tmp) / "LEDGER.md"
            with mock.patch.object(ledger, "RENDER", render):
                ledger.render([])
            assert "No mints recorded yet" in render.read_text()


if __name__ == "__main__":
    unittest.main()
