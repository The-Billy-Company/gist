#!/usr/bin/env python3
"""Hermetic tests for what **gist** certifies (`profile.py`).

The vendored gates test the *method*; this file tests the *claim*. Two contracts
live here and nowhere else, because both are gist's alone:

  * ``measure`` reads the headline numbers out of the rendered certificate, so a
    historical mint reconstructs as published rather than as the sidecars
    currently on disk describe it. The parse has to survive a pattern containing
    a pipe (the alternation class shifts the markdown column) and has to refuse
    a row it cannot read rather than average a guess into the geomean.
  * ``audit`` catches the lies a *well-formed* bundle can still tell — a matrix
    missing the class where a rival won, and an index footprint whose parts do
    not sum to the size it declares.

No real bundle, no git, no benchmark tools.
"""

import json
import tempfile
import unittest
from pathlib import Path

import profile


def _certificate(
    *,
    tally: tuple[int, int, int, int] | None = (12, 12, 0, 0),
    speedups: tuple[tuple[str, str], ...] = (("foo", "4.0x"), ("a|b", "9.0x")),
    trailer: str = "",
) -> str:
    """A certificate carrying gist's macro section, and optionally a later one."""
    out = ["# Dominance-and-Fit Certificate", ""]
    if tally is not None:
        classes, win, parity, loss = tally
        out += [
            "## Layer A — macroscopic dominance (process vs process)",
            "",
            f"gist vs ripgrep across {classes} classes: {win} win · {parity} parity · {loss} loss",
            "",
            "| class | pattern | speedup |",
            "| --- | --- | --- |",
            *(f"| c{i} | {pat} | {ratio} |" for i, (pat, ratio) in enumerate(speedups)),
            "",
        ]
    return "\n".join(out + ([trailer] if trailer else [])) + "\n"


def _measure(text: str) -> dict[str, float | None]:
    """``measure`` never reads the bundle for these numbers — pass a path it can't."""
    return profile.measure(Path("/nonexistent"), text)


class MeasureTests(unittest.TestCase):
    def test_the_tally_is_read_from_the_summary_line(self) -> None:
        got = _measure(_certificate(tally=(12, 10, 1, 1)))
        assert (got["wins"], got["parity"], got["loss"]) == (10.0, 1.0, 1.0)

    def test_a_pattern_containing_a_pipe_does_not_shift_the_speedup_column(self) -> None:
        """`a|b` splits the markdown row, so the column is found by shape, not position.

        4.0 and 9.0 must *both* land: their geomean is exactly 6.0, which a
        dropped or misread alternation row cannot produce.
        """
        assert _measure(_certificate())["rg_geomean"] == 6.0

    def test_an_ambiguous_row_is_skipped_rather_than_guessed(self) -> None:
        """Two ratio-shaped cells in one row is unreadable — it must not be averaged in."""
        text = _certificate(speedups=(("foo", "4.0x"), ("9.0x", "9.0x")))
        assert _measure(text)["rg_geomean"] == 4.0

    def test_a_certificate_without_a_macro_layer_claims_nothing_rather_than_zero(self) -> None:
        """A mint that never raced is not a mint that lost every class."""
        assert all(v is None for v in _measure(_certificate(tally=None)).values())

    def test_a_later_layers_table_cannot_leak_into_the_macro_geomean(self) -> None:
        """The section ends at the next `## ` — a neighbouring 100x row must not count."""
        trailer = "\n".join(
            [
                "## Layer I — scanner mode + ripgrep conformance (no index)",
                "",
                "| class | pattern | speedup |",
                "| --- | --- | --- |",
                "| c9 | bar | 100.0x |",
            ]
        )
        assert _measure(_certificate(trailer=trailer))["rg_geomean"] == 6.0

    def test_every_headline_the_charter_declares_is_one_measure_produces(self) -> None:
        """A charter column the mint can never fill would render as a permanent em dash."""
        assert {h.key for h in profile.CHARTER.headlines} <= set(_measure(_certificate()))


def _bundle(root: Path, *, cells: dict[str, str], index: dict[str, object] | None) -> Path:
    """The smallest bundle shaped enough for one audit check to have an opinion."""
    root.mkdir(parents=True, exist_ok=True)
    (root / "raw").mkdir(exist_ok=True)
    rows = ["class\ttool", *(cell.removesuffix(".json").replace("__", "\t") for cell in cells)]
    (root / "certify_macro.csv").write_text("\n".join(rows) + "\n")
    (root / "certify.csv").write_text(
        "\n".join(["class", *sorted(profile.CERT_CLASSES)]) + "\n"
    )
    for cell, command in cells.items():
        (root / "raw" / cell).write_text(
            json.dumps(
                {"results": [{"command": command, "times": [0.1], "exit_codes": [0]}]}
            )
        )
    (root / "command-log.txt").write_text(
        "".join(f"{cell}\t{command}\n" for cell, command in cells.items())
    )
    if index is not None:
        (root / "index-sizes.json").write_text(json.dumps(index))
    return root


def _full_cells(tools: set[str]) -> dict[str, str]:
    return {
        f"{name}__{tool}.json": f"{tool} pattern ."
        for name in sorted(profile.CERT_CLASSES)
        for tool in sorted(tools)
    }


class AuditCellTests(unittest.TestCase):
    """Layer A's matrix is compared for equality, so a lie by omission is loud."""

    TOOLS = {"gist", "rg"}

    def _audit(self, cells: dict[str, str]) -> list[str]:
        problems: list[str] = []
        with tempfile.TemporaryDirectory() as tmp:
            bundle = _bundle(Path(tmp) / "b", cells=cells, index=None)
            profile._check_cells(bundle, {"runs": 1}, set(self.TOOLS), problems)
        return problems

    def test_a_complete_matrix_is_accepted(self) -> None:
        assert self._audit(_full_cells(self.TOOLS)) == []

    def test_dropping_the_class_a_rival_won_is_caught(self) -> None:
        """The failure mode: race 11 of 12 classes and the geomean improves honestly."""
        cells = _full_cells(self.TOOLS)
        del cells["regex-eol__rg.json"]
        problems = self._audit(cells)
        assert any("cell matrix" in p for p in problems), problems

    def test_a_timed_command_that_masks_producer_status_is_caught(self) -> None:
        """`… 2>&1 | wc -l` exits as wc, so a rival that crashed reads as a fast sample."""
        cells = _full_cells(self.TOOLS)
        cells["regex-eol__rg.json"] = "rg pattern . 2>&1 | wc -l"
        assert any("masks producer status" in p for p in self._audit(cells))

    def test_a_sample_count_disagreeing_with_the_declared_runs_is_caught(self) -> None:
        problems: list[str] = []
        with tempfile.TemporaryDirectory() as tmp:
            bundle = _bundle(Path(tmp) / "b", cells=_full_cells(self.TOOLS), index=None)
            profile._check_cells(bundle, {"runs": 20}, set(self.TOOLS), problems)
        assert any("!= machine.json runs=20" in p for p in problems), problems

    def test_a_command_log_that_disagrees_with_the_raw_export_is_caught(self) -> None:
        cells = _full_cells(self.TOOLS)
        problems: list[str] = []
        with tempfile.TemporaryDirectory() as tmp:
            bundle = _bundle(Path(tmp) / "b", cells=cells, index=None)
            (bundle / "command-log.txt").write_text(
                "".join(f"{cell}\trewritten\n" for cell in cells)
            )
            profile._check_cells(bundle, {"runs": 1}, set(self.TOOLS), problems)
        assert any("differs from raw/" in p for p in problems), problems


class AuditIndexSizeTests(unittest.TestCase):
    """The speed claim is bought with disk, so the footprint has to add up."""

    WHOLE = {
        "schema_version": 2,
        "gist": {
            "posting_bytes": 10,
            "path_bytes": 3,
            "freshness_bytes": 1,
            "required_bytes": 14,
            "workspace_bytes": 20,
            "required_files": {"index.gist": 10, "paths.list": 3, "built.ns": 1},
        },
    }

    def _audit(self, doc: dict[str, object]) -> list[str]:
        problems: list[str] = []
        with tempfile.TemporaryDirectory() as tmp:
            bundle = _bundle(Path(tmp) / "b", cells={}, index=doc)
            profile._check_index_sizes(bundle, problems)
        return problems

    def test_a_footprint_that_sums_is_accepted(self) -> None:
        assert self._audit(self.WHOLE) == []

    def test_a_required_total_smaller_than_its_parts_is_caught(self) -> None:
        """Understating the total is how a footprint comparison becomes flattering."""
        doc = {**self.WHOLE, "gist": {**self.WHOLE["gist"], "required_bytes": 11}}
        assert any("posting + path + freshness" in p for p in self._audit(doc))

    def test_omitting_a_runtime_component_is_caught(self) -> None:
        """A part left out of required_files is a file the query path still needs."""
        listed = {k: v for k, v in self.WHOLE["gist"]["required_files"].items() if k != "built.ns"}
        doc = {**self.WHOLE, "gist": {**self.WHOLE["gist"], "required_files": listed}}
        assert any("required runtime components" in p for p in self._audit(doc))


if __name__ == "__main__":
    unittest.main(verbosity=1)
