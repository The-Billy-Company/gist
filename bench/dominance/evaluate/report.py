#!/usr/bin/env python3
"""Verify, aggregate, and compare gist evaluation bundles.

This is the hermetic half of the evaluator — no timing, no hardware, pure
byte-checking — so it runs anywhere (CI included) and is the thing that turns a
pile of numbers into *evidence*:

  * ``verify_bundle``  — a bundle carries every provenance/corpus/tool field the
    contract demands, the parity precondition passed before any lane was timed,
    no reported number is fabricated, and a *published* bundle came from a clean
    tree.
  * ``verify_claims``  — every prose claim in the contract still resolves to a
    live value from its named artifact, so a README number cannot outlive its
    source.
  * ``aggregate``      — each machine's operational envelope (footprint ratio,
    RSS, throughput, build/first-query latency, peak qps) + cross-machine
    footprint consistency, with unmeasured lanes surfaced, never smoothed away.
  * ``compare``        — two machines under the cross-machine policy: the
    hardware-invariant index/corpus footprint ratio and scaling shape only,
    never absolute milliseconds.

Cold/warm query dominance and rg drop-in correctness are the Certificate of
Optimality's; this module never restates them. stdlib only (tomllib).
"""

from __future__ import annotations

import json
from pathlib import Path
import tomllib


HERE = Path(__file__).resolve().parent
KERNEL = HERE.parents[2]
REPO = KERNEL.parents[2]
CONTRACT = KERNEL / "contract" / "performance_evidence.toml"
ARTIFACT = HERE / "artifact"

_SEMVER_OR_SHA = ("sha256:", "v", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9")


def load_contract(path: Path = CONTRACT) -> dict:
    """Parse the performance-evidence contract."""
    return tomllib.loads(path.read_text())


# ── bundle verification ───────────────────────────────────────────────────────
def verify_bundle(bundle: dict, contract: dict, *, require_clean: bool) -> list[str]:
    """Return a list of contract violations for one bundle ([] == valid)."""
    problems: list[str] = []
    meta = contract["meta"]
    prov = contract["provenance"]
    method = contract["methodology"]

    if bundle.get("schema_version") != meta["schema_version"]:
        problems.append(
            f"schema_version {bundle.get('schema_version')} != contract {meta['schema_version']}"
        )

    machine = bundle.get("machine") or {}
    problems.extend(
        f"machine missing provenance key: {key}"
        for key in prov["machine_keys"]
        if key not in machine
    )
    if not isinstance(machine.get("git_commit"), str) or len(machine.get("git_commit", "")) < 7:
        problems.append("machine.git_commit is not a resolved object id")

    corpora = bundle.get("corpora") or {}
    if not corpora:
        problems.append("bundle measured no corpora")
    for cid, block in corpora.items():
        problems.extend(
            f"corpus {cid} missing key: {key}" for key in prov["corpus_keys"] if key not in block
        )

    problems.extend(
        f"tool {tool} identity is not semver/sha256: {identity!r}"
        for tool, identity in (bundle.get("tools") or {}).items()
        if not str(identity).startswith(_SEMVER_OR_SHA)
    )

    bmeth = bundle.get("methodology") or {}
    problems.extend(
        f"methodology.{key} {bmeth.get(key)} != contract {method[key]}"
        for key in ("runs", "warmup", "alpha", "bootstrap_seed")
        if bmeth.get(key) != method[key]
    )

    problems += _verify_parity_gate(bundle)
    problems += _verify_operational(bundle)

    if require_clean and machine.get("git_dirty"):
        problems.append("published bundle came from a dirty tree (git_dirty=true)")
    if require_clean and bundle.get("exploratory"):
        problems.append("published bundle is flagged exploratory")
    return problems


def _verify_parity_gate(bundle: dict) -> list[str]:
    """The timed lanes are legitimate only if the parity precondition passed."""
    parity = (bundle.get("regimes") or {}).get("parity") or []
    if not parity:
        return [
            "no parity precondition recorded — lanes may not be timed without proven correctness"
        ]
    problems: list[str] = []
    for row in parity:
        if row.get("status") == "failed":
            problems.append(f"parity failed for class {row.get('class')}: {row.get('note', '')}")
        engines = row.get("engines") or {}
        if row.get("status") == "ok" and not (engines.get("parallel") and engines.get("serial")):
            problems.append(f"parity class {row.get('class')} not proven on both engines")
    return problems


def _verify_operational(bundle: dict) -> list[str]:
    """Fail closed on the operational regimes: a reported number must be internally
    consistent (never fabricated), and an unmeasurable value is an honest null."""
    problems: list[str] = []
    reg = bundle.get("regimes") or {}

    life = reg.get("lifecycle")
    if life is not None:
        if not isinstance(life, dict):
            problems.append("lifecycle regime is malformed")
        elif life.get("build_ms") is not None and life["build_ms"] <= 0:
            problems.append(f"lifecycle build_ms {life['build_ms']} is not a positive latency")

    res = reg.get("resource")
    if res is not None:
        if not isinstance(res, dict):
            problems.append("resource regime is malformed")
        elif res.get("index_over_corpus") is not None and not (
            res.get("index_bytes", 0) > 0 and res.get("corpus_bytes", 0) > 0
        ):
            problems.append(
                "resource index_over_corpus reported without positive index+corpus bytes"
            )

    conc = reg.get("concurrency")
    if conc is not None:
        if not isinstance(conc, list):
            problems.append("concurrency regime is malformed")
        else:
            problems.extend(
                f"concurrency point workers={p.get('workers')} has qps but no queries (fabricated?)"
                for p in conc
                if p.get("qps") is not None and not p.get("queries")
            )

    scale = reg.get("scale")
    if scale is not None and not isinstance(scale, list):
        problems.append("scale regime is malformed")
    return problems


# ── claim freshness ───────────────────────────────────────────────────────────
def verify_claims(contract: dict, repo: Path = REPO) -> tuple[list[str], dict[str, object]]:
    """Resolve each contract claim to a live value; return (problems, values)."""
    problems: list[str] = []
    values: dict[str, object] = {}
    for claim in contract.get("claim", []):
        cid = claim["id"]
        source = repo / claim["source"]
        if not source.exists():
            problems.append(f"claim {cid}: source missing {claim['source']}")
            continue
        try:
            values[cid] = _resolve_claim(claim, source)
        except (ValueError, KeyError, json.JSONDecodeError) as exc:
            problems.append(f"claim {cid}: cannot resolve ({exc})")
    return problems, values


def _resolve_claim(claim: dict, source: Path) -> object:
    kind = claim["kind"]
    if kind == "json_ratio":
        return _index_over_corpus(source)
    msg = f"unknown claim kind {kind}"
    raise ValueError(msg)


def _index_over_corpus(index_sizes: Path) -> float:
    doc = json.loads(index_sizes.read_text())
    required = doc["gist"]["required_bytes"]
    machine = index_sizes.parent / "machine.json"
    corpus = json.loads(machine.read_text())["corpus_total_bytes"]
    if not corpus:
        msg = "corpus_total_bytes is zero"
        raise ValueError(msg)
    return round(required / corpus, 4)


# ── aggregation ───────────────────────────────────────────────────────────────
def _machine_summary(bundle: dict) -> dict:
    """One machine's operational envelope: footprint ratio, RSS, throughput,
    build/first-query latency, and peak concurrent qps."""
    m = bundle.get("machine") or {}
    reg = bundle.get("regimes") or {}
    res = reg.get("resource") or {}
    life = reg.get("lifecycle") or {}
    conc = reg.get("concurrency") or []
    peak_qps = max((p["qps"] for p in conc if p.get("qps") is not None), default=None)
    return {
        "machine_id": m.get("machine_id", "?"),
        "arch": m.get("arch"),
        "os": m.get("os"),
        "index_over_corpus": res.get("index_over_corpus"),
        "peak_rss_kb": res.get("peak_rss_kb"),
        "scan_throughput_mb_s": res.get("scan_throughput_mb_s"),
        "build_ms": life.get("build_ms"),
        "first_query_ms": life.get("first_query_ms"),
        "peak_qps": peak_qps,
    }


def _footprint_consistency(bundles: list[dict]) -> dict:
    """The index/corpus ratio is hardware-invariant, so it should be near-equal
    across machines; a wide spread means a real index-format difference, not noise."""
    ratios = {
        (b.get("machine") or {}).get("machine_id", "?"): r
        for b in bundles
        if (r := ((b.get("regimes") or {}).get("resource") or {}).get("index_over_corpus"))
        is not None
    }
    vals = list(ratios.values())
    spread = round(max(vals) - min(vals), 4) if len(vals) >= 2 else None
    return {"ratios": ratios, "spread": spread}


def aggregate(bundles: list[dict]) -> dict:
    """Cross-machine operational report: per-machine envelope + footprint consistency."""
    return {
        "machines": [_machine_summary(b) for b in bundles],
        "footprint": _footprint_consistency(bundles),
        "unsupported": _unsupported(bundles),
    }


def _unsupported(bundles: list[dict]) -> list[dict]:
    """Surface the honest nulls — a lane that could not measure, never smoothed away."""
    out = []
    for bundle in bundles:
        mid = (bundle.get("machine") or {}).get("machine_id", "?")
        reg = bundle.get("regimes") or {}
        life = reg.get("lifecycle")
        if isinstance(life, dict) and life.get("build_ms") is None:
            out.append({"machine_id": mid, "regime": "lifecycle", "note": "build failed"})
        res = reg.get("resource")
        if isinstance(res, dict) and res.get("index_over_corpus") is None:
            out.append({"machine_id": mid, "regime": "resource", "note": "no index/corpus ratio"})
        if reg.get("concurrency") == []:
            out.append({"machine_id": mid, "regime": "concurrency", "note": "daemon unavailable"})
        if reg.get("scale") == []:
            out.append({"machine_id": mid, "regime": "scale", "note": "no foreign corpora"})
    return out


def _scale_shape(bundle: dict) -> list[dict]:
    """Foreign-corpus points sorted by size — the build/query growth curve."""
    points = (bundle.get("regimes") or {}).get("scale") or []
    return sorted(
        (
            {
                "corpus": p.get("corpus"),
                "bytes": p.get("total_bytes"),
                "build_ms": p.get("build_ms"),
                "cold_p50_ms": p.get("cold_p50_ms"),
            }
            for p in points
        ),
        key=lambda p: p.get("bytes") or 0,
    )


def compare(bundle_a: dict, bundle_b: dict) -> dict:
    """Two machines under the cross-machine policy: hardware-invariant quantities
    only — the index/corpus footprint ratio and the scaling shape, never ms."""
    a_id = (bundle_a.get("machine") or {}).get("machine_id", "a")
    b_id = (bundle_b.get("machine") or {}).get("machine_id", "b")
    fp = _footprint_consistency([bundle_a, bundle_b])
    return {
        "a": a_id,
        "b": b_id,
        "index_over_corpus": fp["ratios"],
        "footprint_spread": fp["spread"],
        "scale_shape": {a_id: _scale_shape(bundle_a), b_id: _scale_shape(bundle_b)},
    }


# ── rendering ───────────────────────────────────────────────────────────────
def _num(value: object, suffix: str = "") -> str:
    return f"{value}{suffix}" if value is not None else "—"


def render_report(agg: dict, claims: dict[str, object]) -> str:
    """Markdown aggregate report from verified bundles + resolved claims.

    The operational envelope beside the Dominance-and-Fit Certificate: cold/warm
    query dominance is the certificate's, not restated here.
    """
    lines = [
        "# gist evaluation matrix — operational envelope",
        "",
        "_The operational complement to the [Dominance-and-Fit Certificate](../certify/) "
        "(which owns cold/warm dominance + correctness). Absolute build ms, RSS, and "
        "qps are machine-local; only the index/corpus footprint ratio and scaling "
        "shape are compared across machines._",
        "",
        "## Machines",
        "",
        "| machine | arch | index/corpus | peak RSS (KiB) | scan MB/s | build ms | first-query ms | peak qps |",
        "|---|---|--:|--:|--:|--:|--:|--:|",
    ]
    lines.extend(
        f"| `{m['machine_id']}` | {m.get('arch', '?')} | {_num(m['index_over_corpus'])} | "
        f"{_num(m['peak_rss_kb'])} | {_num(m['scan_throughput_mb_s'])} | "
        f"{_num(m['build_ms'])} | {_num(m['first_query_ms'])} | {_num(m['peak_qps'])} |"
        for m in agg["machines"]
    )
    fp = agg.get("footprint") or {}
    if len(fp.get("ratios") or {}) >= 2:
        lines += [
            "",
            "## Footprint consistency (index/corpus is hardware-invariant — spread ≈ 0 expected)",
            "",
            "- " + " · ".join(f"`{mid}` {r}" for mid, r in fp["ratios"].items()),
            f"- spread: {_num(fp.get('spread'))}",
        ]
    if agg["unsupported"]:
        lines += ["", "## Unmeasured lanes (surfaced, not smoothed)"]
        lines += [f"- `{u['machine_id']}` {u['regime']}: {u['note']}" for u in agg["unsupported"]]
    if claims:
        lines += ["", "## Bound claims (current source values)"]
        lines += [f"- `{cid}` → {value}" for cid, value in sorted(claims.items())]
    return "\n".join(lines) + "\n"
