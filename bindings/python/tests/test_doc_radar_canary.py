"""The doc_radar canary as a gate (ADR-352, plan steps 4 & 6).

Asserts the two acceptance criteria the plan puts on the canary:

- **byte-equivalent findings** — GIST returns exactly what `rg` does over
  doc_radar's *real* query corpus (marker discovery + every ADR `still_here`
  pin), so swapping the engine cannot change a single radar verdict; and
- **warm-path measurement present** — the batch is timed three ways, so the
  graduation decision (step 6) rests on numbers, not the plan's assumption.

Skips cleanly where the pieces aren't present (no `gist` binary → build with
`make install-gist`; no `rg`; no repo checkout), so it never blocks CI on a
machine without the search engines built.
"""

from __future__ import annotations

import shutil

import pytest

from canary.doc_radar import _find_root, _gist_available, collect_queries, run_canary


_HAVE_ENGINES = _gist_available() and shutil.which("rg") is not None
needs_engines = pytest.mark.skipif(not _HAVE_ENGINES, reason="need gist + rg on PATH")


@needs_engines
def test_canary_findings_are_byte_equivalent() -> None:
    report = run_canary()
    assert report.compared, "canary compared no queries — corpus failed to load"
    assert report.mismatches == [], (
        f"GIST diverged from rg on {len(report.mismatches)} query(ies): "
        f"{[(m.origin, m.rg, m.gist) for m in report.mismatches[:5]]}"
    )
    assert report.equivalent


@needs_engines
def test_canary_measures_the_warm_path() -> None:
    """The whole point of the canary (step 6) is a warm-vs-cold-vs-rg number;
    fail if the corpus is so empty we never timed the repeated-query path."""
    root = _find_root()
    _, counts = collect_queries(root)
    if not counts:
        pytest.skip("no still_here corpus (PyYAML absent) — run with the dev group")
    report = run_canary()
    assert {"rg", "gist_warm", "gist_cold"} <= report.timings_ms.keys()
    assert all(v > 0 for v in report.timings_ms.values())


@needs_engines
def test_no_pattern_is_unsupported_in_the_radar_corpus() -> None:
    """Every pattern the radar uses lives inside GIST's linear-time engine — a
    regression here (a new PCRE-only still_here pin) is a real graduation
    blocker, surfaced loud rather than silently falling back."""
    report = run_canary()
    assert report.unsupported == [], (
        f"patterns outside GIST's engine: {[(u.origin, u.pattern) for u in report.unsupported]}"
    )
