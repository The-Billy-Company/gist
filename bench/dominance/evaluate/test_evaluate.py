#!/usr/bin/env python3
"""Hermetic tests for the gist evaluator's verification + aggregation core.

These are biased-oracle adverse tests: each derives its expectation from the
contract (not from re-running the code under test) and each asserts a DISTINCT
failure the verifier must catch — a missing provenance key, an ungated parity
precondition, a fabricated concurrency point, a non-positive build latency, a
footprint ratio with no bytes behind it, a dirty publication, a stale claim, and
a cross-machine footprint mistake. A test that merely mirrored `verify_bundle`
would pass on a broken verifier; these fail it.

The matrix measures the OPERATIONAL ENVELOPE only (lifecycle / resource / scale /
concurrency); cold/warm query dominance is the certificate's and is not asserted
here.

Run:  python3 -m pytest bench/dominance/evaluate/test_evaluate.py
"""

# ruff: noqa: S101 — a pytest module (asserts are the assertion mechanism);
# it lives beside the code it audits, not under a tests/ dir.

from __future__ import annotations

import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import report  # noqa: E402

CONTRACT = report.load_contract()
CLASSES = tuple(cls for cls, _, _ in __import__("regimes").PROBES)


def valid_bundle(machine_id: str = "apple-m4-max-darwin-arm64") -> dict:
    """A minimal bundle that satisfies the contract — the golden baseline."""
    method = CONTRACT["methodology"]
    return {
        "schema_version": CONTRACT["meta"]["schema_version"],
        "exploratory": False,
        "machine": {
            k: (
                machine_id
                if k == "machine_id"
                else ("abc1234def" if k == "git_commit" else (False if k == "git_dirty" else "x"))
            )
            for k in CONTRACT["provenance"]["machine_keys"]
        },
        "corpora": {
            "billy": {
                "corpus_id": "billy",
                "file_count": 10,
                "total_bytes": 1000,
                "manifest_sha256": "d" * 64,
            }
        },
        # The operational lanes exercise gist alone; rg is the parity oracle.
        "tools": dict.fromkeys(("gist", "rg"), f"sha256:{'a' * 64}"),
        "methodology": {
            "runs": method["runs"],
            "warmup": method["warmup"],
            "bootstrap_resamples": method["bootstrap_resamples"],
            "bootstrap_seed": method["bootstrap_seed"],
            "alpha": method["alpha"],
            "quantiles": method["quantiles"],
        },
        "regimes": {
            "parity": [
                {
                    "class": cls,
                    "kind": "literal",
                    "status": "ok",
                    "engines": {"parallel": True, "serial": True},
                }
                for cls in CLASSES
            ],
            "lifecycle": {
                "build_ms": 1200.0,
                "first_query_ms": 5.0,
                "incremental": [{"event": "add", "refresh_ms": 10.0}],
            },
            "resource": {
                "index_bytes": 200,
                "corpus_bytes": 1000,
                "index_over_corpus": 0.2,
                "peak_rss_kb": 30000,
                "scan_throughput_mb_s": 500.0,
            },
            "concurrency": [
                {"workers": 1, "queries": 20, "qps": 100.0, "p50_ms": 1, "p95_ms": 2, "p99_ms": 3},
                {"workers": 4, "queries": 80, "qps": 300.0, "p50_ms": 1, "p95_ms": 2, "p99_ms": 3},
            ],
        },
    }


def test_golden_bundle_is_valid():
    assert report.verify_bundle(valid_bundle(), CONTRACT, require_clean=True) == []


def test_missing_provenance_key_fails():
    b = valid_bundle()
    del b["machine"]["filesystem"]
    problems = report.verify_bundle(b, CONTRACT, require_clean=False)
    assert any("filesystem" in p for p in problems)


def test_ungated_parity_is_rejected():
    b = valid_bundle()
    b["regimes"]["parity"] = []
    assert any("parity" in p for p in report.verify_bundle(b, CONTRACT, require_clean=False))


def test_single_engine_parity_is_rejected():
    b = valid_bundle()
    b["regimes"]["parity"][0]["engines"]["serial"] = False
    assert any("both engines" in p for p in report.verify_bundle(b, CONTRACT, require_clean=False))


def test_failed_parity_blocks_bundle():
    b = valid_bundle()
    b["regimes"]["parity"][2] = {"class": CLASSES[2], "status": "failed", "note": "gist != rg"}
    assert any("parity failed" in p for p in report.verify_bundle(b, CONTRACT, require_clean=False))


def test_fabricated_concurrency_point_fails():
    # A qps with no queries behind it is a fabricated throughput — fail closed.
    b = valid_bundle()
    b["regimes"]["concurrency"][0] = {"workers": 1, "queries": 0, "qps": 100.0}
    assert any("fabricated" in p for p in report.verify_bundle(b, CONTRACT, require_clean=False))


def test_nonpositive_build_latency_fails():
    b = valid_bundle()
    b["regimes"]["lifecycle"]["build_ms"] = 0
    assert any(
        "positive latency" in p for p in report.verify_bundle(b, CONTRACT, require_clean=False)
    )


def test_footprint_ratio_without_bytes_fails():
    # index_over_corpus reported but no index/corpus bytes to justify it → fabricated ratio.
    b = valid_bundle()
    b["regimes"]["resource"]["index_bytes"] = 0
    assert any(
        "index_over_corpus" in p for p in report.verify_bundle(b, CONTRACT, require_clean=False)
    )


def test_dirty_publication_is_refused():
    b = valid_bundle()
    b["machine"]["git_dirty"] = True
    b["exploratory"] = True
    problems = report.verify_bundle(b, CONTRACT, require_clean=True)
    assert any("dirty" in p for p in problems)
    # ...but a non-published (exploratory) verify tolerates it.
    assert report.verify_bundle(b, CONTRACT, require_clean=False) == []


def test_schema_version_mismatch_fails():
    b = valid_bundle()
    b["schema_version"] = 999
    assert any(
        "schema_version" in p for p in report.verify_bundle(b, CONTRACT, require_clean=False)
    )


def test_methodology_override_is_unpublishable():
    b = valid_bundle()
    b["methodology"]["runs"] = 3
    assert any("runs" in p for p in report.verify_bundle(b, CONTRACT, require_clean=False))


def test_aggregate_summarizes_operational_envelope():
    agg = report.aggregate([valid_bundle()])
    m = agg["machines"][0]
    assert m["index_over_corpus"] == 0.2
    assert m["build_ms"] == 1200.0
    assert m["peak_qps"] == 300.0  # max over the worker points, not the first


def test_footprint_spread_is_zero_for_identical_ratios():
    # The index/corpus ratio is hardware-invariant: two machines that built the
    # same index over the same corpus must show ~zero spread.
    a, b = valid_bundle("machine-a"), valid_bundle("machine-b")
    agg = report.aggregate([a, b])
    assert agg["footprint"]["spread"] == pytest.approx(0.0)


def test_footprint_spread_surfaces_a_real_difference():
    a, b = valid_bundle("machine-a"), valid_bundle("machine-b")
    b["regimes"]["resource"]["index_over_corpus"] = 0.5  # a real index-format divergence
    out = report.compare(a, b)
    assert out["footprint_spread"] == pytest.approx(0.3)


def test_claims_resolve_against_live_artifacts():
    problems, values = report.verify_claims(CONTRACT)
    # Every claim source must at least be resolvable OR reported as a problem —
    # never silently absent. The union must cover all declared claims.
    declared = {c["id"] for c in CONTRACT["claim"]}
    resolved = set(values)
    reported = {p.split(":")[0].replace("claim ", "").strip() for p in problems}
    assert declared <= (resolved | reported)


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
