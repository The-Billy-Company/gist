#!/usr/bin/env python3
"""gist certify — Layer F report (the codex self-index).

Reads the JSONL the `codex-scale` harness (`bench/codex/scale.zig`, driven by
`bench/codex/race.sh`) emits over real-source corpus slices, plus the sibling
compressor baselines, and splices a self-contained **Layer F** section into
CERTIFICATE.md between stable sentinels, idempotent across re-mints.

Layer F is where gist's *space* claim becomes a receipt. `codex` is the FM-index
gist persists so its corpus is searchable-yet-compressed; the harness is already
fail-closed by construction — it `die()`s on a restore mismatch, a
count-vs-naive-oracle disagreement, or a cento save/load drift — so a JSONL that
exists at all is a decodability + correctness receipt. This report re-asserts the
five load-bearing invariants over the emitted numbers and refuses to splice a
section that any of them violates:

  F1 DECODABLE          every build point restores byte-exact (`restore_ok`).
  F2 SUB-ENTROPY SPACE  the *searchable* index costs < the order-0 entropy coder
                        (`bits_per_char < h0_bits`) at every size — a plain coder
                        can't answer count/locate; the index does.
  F3 COUNT IS n-FREE    count(P) is O(|P|), not O(n): per m, count latency is flat
                        as the corpus grows 16×, while the naive scan oracle grows
                        ~linearly and count beats it by ≥ NAIVE_MIN_SPEEDUP×.
  F4 CHEAP BYTE-EXACT   reload is < LOAD_CEIL of build cost (the harness die proves
                        byte-exactness; this proves it is also nearly free).
  F5 SELF-RECOGNITION   the codex prices its own corpus's strings ≥ CENTO_RATIO×
                        cheaper than foreign strings (cento) — kinship, not luck.

stdlib only.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

START = "<!-- CODEX-LAYER-START -->"
END = "<!-- CODEX-LAYER-END -->"
HEADER = "## Layer F — codex self-index (compressed, searchable, decodable)"

# F2: the searchable index must beat the order-0 entropy coder at every size.
# F3: count latency may grow at most this much across a 16× corpus (flat ⇒ n-free);
# count must beat the naive scan at the LARGEST corpus by at least this factor (the
# honest asymptotic point — the margin is smaller on a tiny slice by construction);
# and across its asymptotic step (the two largest slices) the naive scan must grow at
# least this fraction of that step's corpus ratio, proving it is the O(n) baseline
# count escapes. Slope is read on the asymptotic step, not the full range: a tiny
# slice is fixed-per-query-cost-bound, so a full-range slope deflates a genuinely
# linear scan into looking sublinear.
COUNT_FLAT_FACTOR = 2.0
NAIVE_MIN_SPEEDUP = 100.0
NAIVE_GROWTH_FRAC = 0.5
# F4: a reload costs at most this fraction of a from-scratch build.
LOAD_CEIL = 0.05
# F5: the codex prices its own strings this much cheaper than foreign, and native
# stays comfortably sub-byte.
CENTO_RATIO_FLOOR = 10.0
CENTO_NATIVE_CEIL = 1.0


def _rows(path: Path, kind: str) -> list[dict]:
    out = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        doc = json.loads(line)
        if doc.get("kind") == kind:
            out.append(doc)
    return out


def _by_raw(rows: list[dict]) -> dict[int, dict]:
    return {int(r["raw_bytes"]): r for r in rows}


def _bpc(comp_bytes, raw_bytes: int) -> float | None:
    if comp_bytes in (None, "null") or not raw_bytes:
        return None
    return float(comp_bytes) * 8.0 / raw_bytes


def _mib(raw_bytes: int) -> str:
    return f"{raw_bytes / (1 << 20):.0f}MB"


class Fail(Exception):
    """A Layer-F invariant did not hold — refuse to splice."""


def render(scale: Path, compressors: Path, machine: str, zig: str, csv_out: Path) -> str:
    builds = sorted(_rows(scale, "build"), key=lambda r: r["raw_bytes"])
    persists = _by_raw(_rows(scale, "persist"))
    queries = _rows(scale, "query")
    centos = sorted(_rows(scale, "cento"), key=lambda r: r["raw_bytes"])
    comps: dict[int, dict] = {}
    if compressors.exists():
        comps = _by_raw(
            [json.loads(ln) for ln in compressors.read_text().splitlines() if ln.strip()]
        )
    if not builds:
        raise Fail("no build points in scale.jsonl")

    sizes = [int(b["raw_bytes"]) for b in builds]
    n_min, n_max = sizes[0], sizes[-1]

    # ── F1 decodable ─────────────────────────────────────────────────────────
    undecodable = [_mib(int(b["raw_bytes"])) for b in builds if not b.get("restore_ok")]
    if undecodable:
        raise Fail(f"restore FAILED at {', '.join(undecodable)} — index is not byte-exact")

    # ── F2 sub-entropy searchable space ──────────────────────────────────────
    over_h0 = [
        f"{_mib(int(b['raw_bytes']))} ({b['bits_per_char']:.2f} ≥ H0 {b['h0_bits']:.2f})"
        for b in builds
        if float(b["bits_per_char"]) >= float(b["h0_bits"])
    ]
    if over_h0:
        raise Fail("searchable index did not beat the order-0 coder at: " + ", ".join(over_h0))

    # ── F3 count is n-independent (O(m)), naive scan is O(n) ──────────────────
    ms = sorted({int(q["m"]) for q in queries})
    q_by = {(int(q["raw_bytes"]), int(q["m"])): q for q in queries}
    flat_rows = []  # (m, count@min, count@max, ratio)
    for m in ms:
        lo, hi = q_by.get((n_min, m)), q_by.get((n_max, m))
        if not lo or not hi:
            continue
        c_lo = float(lo["count_ns_per_query"])
        c_hi = float(hi["count_ns_per_query"])
        ratio = c_hi / c_lo if c_lo else float("inf")
        flat_rows.append((m, c_lo, c_hi, ratio))
        if ratio > COUNT_FLAT_FACTOR:
            raise Fail(
                f"count(m={m}) grew {ratio:.2f}× across a {n_max // n_min}× corpus "
                f"(> {COUNT_FLAT_FACTOR}×) — not n-independent"
            )
    if not flat_rows:
        raise Fail("no shared m across sizes — cannot prove count flatness")

    # naive oracle: measured only where naive_ns_per_query > 0. Count must beat it
    # everywhere, by a wide margin at the LARGEST corpus (the asymptotic point), and
    # the naive scan itself must grow ~linearly in n (⇒ it is the O(n) baseline).
    naive_pts = sorted(
        (
            (
                int(q["raw_bytes"]),
                int(q["m"]),
                float(q["count_ns_per_query"]),
                float(q["naive_ns_per_query"]),
            )
            for q in queries
            if float(q.get("naive_ns_per_query", -1)) > 0
        ),
        key=lambda t: t[0],
    )
    if not naive_pts:
        raise Fail("no naive-oracle rows — cannot prove count beats the linear scan")
    losing = [_mib(rb) for rb, _, c, n in naive_pts if n <= c]
    if losing:
        raise Fail("count did not beat the naive scan at: " + ", ".join(losing))
    naive_lo, naive_hi = naive_pts[0], naive_pts[-1]
    big_speedup = naive_hi[3] / naive_hi[2]
    if big_speedup < NAIVE_MIN_SPEEDUP:
        raise Fail(
            f"count beat the naive scan by only {big_speedup:.0f}× at {_mib(naive_hi[0])} "
            f"(< {NAIVE_MIN_SPEEDUP:.0f}×)"
        )
    # Prove the naive scan is the O(n) baseline from its ASYMPTOTIC slope — the two
    # largest slices, where the fixed per-query cost that dominates a tiny corpus is
    # amortized away and only the linear scan term remains. A full-range slope folds
    # that fixed cost in and understates linearity (a genuinely O(n) scan reads as
    # sublinear across 1MB→16MB purely because the 1MB point is overhead-bound).
    seg_lo, seg_hi = naive_lo, naive_hi
    naive_growth = naive_hi[3] / naive_lo[3] if naive_lo[3] else float("inf")
    if len(naive_pts) >= 2 and naive_pts[-2][0] < naive_hi[0]:
        seg_lo, seg_hi = naive_pts[-2], naive_pts[-1]
        naive_growth = seg_hi[3] / seg_lo[3]
        need = NAIVE_GROWTH_FRAC * (seg_hi[0] / seg_lo[0])
        if naive_growth < need:
            raise Fail(
                f"naive oracle grew only {naive_growth:.1f}× across the asymptotic "
                f"{seg_hi[0] // seg_lo[0]}× step ({_mib(seg_lo[0])}→{_mib(seg_hi[0])}, "
                f"< {need:.1f}×) — cannot claim it is the O(n) baseline"
            )

    # ── F4 cheap byte-exact persistence ──────────────────────────────────────
    heavy = [
        f"{_mib(rb)} ({p['load_over_build']:.3f})"
        for rb, p in sorted(persists.items())
        if float(p["load_over_build"]) >= LOAD_CEIL
    ]
    if heavy:
        raise Fail("reload cost ≥ ceiling at: " + ", ".join(heavy))

    # ── F5 self-recognition (cento) ──────────────────────────────────────────
    if not centos:
        raise Fail("no cento rows — cannot prove self-recognition")
    for c in centos:
        native = float(c["native_bits_per_byte"])
        foreign = float(c["foreign_bits_per_byte"])
        ratio = foreign / native if native else float("inf")
        if native >= CENTO_NATIVE_CEIL:
            raise Fail(
                f"cento native {native:.2f} ≥ {CENTO_NATIVE_CEIL} bits/byte at {_mib(int(c['raw_bytes']))}"
            )
        if ratio < CENTO_RATIO_FLOOR:
            raise Fail(
                f"cento ratio {ratio:.1f}× < {CENTO_RATIO_FLOOR}× at {_mib(int(c['raw_bytes']))}"
            )

    # ── all invariants hold — render + sidecar CSV ───────────────────────────
    with csv_out.open("w") as fh:
        fh.write("raw_bytes,bits_per_char,tree_bpc,h0,h2,gzip9_bpc,zstd19_bpc,xz9_bpc,restore_ok\n")
        for b in builds:
            rb = int(b["raw_bytes"])
            tree_bpc = float(b["tree_bytes"]) * 8.0 / rb
            comp = comps.get(rb, {})
            fh.write(
                f"{rb},{b['bits_per_char']:.3f},{tree_bpc:.3f},{b['h0_bits']:.3f},{b['h2_bits']:.3f},"
                f"{_bpc(comp.get('gzip9'), rb) or ''},{_bpc(comp.get('zstd19'), rb) or ''},"
                f"{_bpc(comp.get('xz9'), rb) or ''},{int(bool(b['restore_ok']))}\n"
            )

    largest = builds[-1]
    lg_rb = int(largest["raw_bytes"])
    lg_comp = comps.get(lg_rb, {})
    tree_bpc = float(largest["tree_bytes"]) * 8.0 / lg_rb

    lines = [
        START,
        HEADER,
        "",
        (
            "_The **codex** is the FM-index gist persists so the corpus is *searchable while "
            "compressed* — a self-index, not a blob. `zig build lab` builds the `codex-scale` "
            "harness (`bench/codex/scale.zig`); `bench/codex/race.sh` runs it over deterministic "
            "real-source slices and sizes the identical slices with gzip/zstd/xz. The harness is "
            "**fail-closed by construction** — it aborts on a restore mismatch, a "
            "count-vs-naive-oracle disagreement, or a cento save/load drift — so a spliced Layer F "
            "is itself the decodability + correctness receipt. This report re-asserts five "
            "invariants over the emitted numbers and refuses to splice if any fails._"
        ),
        "",
        f"- machine: **{machine}** · zig `{zig}` · corpus slices {_mib(n_min)}–{_mib(n_max)} of deterministic real source",
        "",
        "**F1 · decodable** — every build point restores byte-exact (harness `die` on mismatch).  "
        "**F2 · sub-entropy searchable space** — the index beats the order-0 entropy coder at every size.",
        "",
        "| slice | index bits/char | searchable core (tree) | H0 | H2 | gzip-9 | zstd-19 | xz-9 | restore |",
        "|---|--:|--:|--:|--:|--:|--:|--:|:--:|",
    ]
    for b in builds:
        rb = int(b["raw_bytes"])
        comp = comps.get(rb, {})
        core = float(b["tree_bytes"]) * 8.0 / rb

        def g(key: str, comp: dict = comp, rb: int = rb) -> str:
            v = _bpc(comp.get(key), rb)
            return f"{v:.2f}" if v is not None else "—"

        lines.append(
            f"| {_mib(rb)} | **{float(b['bits_per_char']):.2f}** | {core:.2f} | {float(b['h0_bits']):.2f} "
            f"| {float(b['h2_bits']):.2f} | {g('gzip9')} | {g('zstd19')} | {g('xz9')} | ✓ |"
        )

    lines += [
        "",
        (
            f"At {_mib(lg_rb)} the searchable index is **{float(largest['bits_per_char']):.2f} bits/char** "
            f"(H0 {float(largest['h0_bits']):.2f}); its searchable BWT core is {tree_bpc:.2f} bits/char, "
            f"beside xz-9's {(_bpc(lg_comp.get('xz9'), lg_rb) or 0):.2f}. The pure compressors are smaller "
            "but **cannot count or locate a pattern without decompressing the whole slice** — the codex "
            "answers both while staying below the byte-wise entropy coder."
        ),
        "",
        "**F3 · count(P) is O(|P|), not O(n)** — count latency is flat as the corpus grows "
        f"{n_max // n_min}×, while the naive linear scan grows with n and count beats it by "
        f"**{big_speedup:.0f}×** at {_mib(naive_hi[0])}.",
        "",
        f"| m | count @ {_mib(n_min)} | count @ {_mib(n_max)} | growth |",
        "|--:|--:|--:|--:|",
    ]
    for m, c_lo, c_hi, ratio in flat_rows:
        lines.append(f"| {m} | {c_lo:.0f} ns | {c_hi:.0f} ns | {ratio:.2f}× |")
    lines += [
        "",
        (
            f"The naive oracle at m={naive_lo[1]} grows {naive_lo[3]:.0f} ns → {naive_hi[3]:.0f} ns "
            f"end-to-end, and {seg_lo[3]:.0f} ns → {seg_hi[3]:.0f} ns ({naive_growth:.1f}×) across the "
            f"asymptotic {seg_hi[0] // seg_lo[0]}× step where its fixed per-query cost is amortized — "
            "the O(n) scan gist does not do; count stays flat because it walks the BWT, never the text."
        ),
        "",
        (
            f"**F4 · cheap byte-exact reload** — persisting + reloading the index costs "
            f"< {LOAD_CEIL:.0%} of a from-scratch build "
            f"(measured {min(float(p['load_over_build']) for p in persists.values()):.1%}–"
            f"{max(float(p['load_over_build']) for p in persists.values()):.1%}); the harness `die` on any "
            "save/load drift is the byte-exactness proof."
        ),
        "",
        (
            f"**F5 · self-recognition (cento)** — the codex prices its own corpus's strings at "
            f"{min(float(c['native_bits_per_byte']) for c in centos):.2f}–"
            f"{max(float(c['native_bits_per_byte']) for c in centos):.2f} bits/byte vs foreign strings at "
            f"{min(float(c['foreign_bits_per_byte']) for c in centos):.1f}–"
            f"{max(float(c['foreign_bits_per_byte']) for c in centos):.1f} — a "
            f"**{min(float(c['foreign_bits_per_byte']) / float(c['native_bits_per_byte']) for c in centos):.0f}–"
            f"{max(float(c['foreign_bits_per_byte']) / float(c['native_bits_per_byte']) for c in centos):.0f}× "
            "gap**: kinship the index recognizes, not luck."
        ),
        "",
        (
            "> Fail-closed on all five: F2 (index ≥ H0), F3 (count grows > "
            f"{COUNT_FLAT_FACTOR}× across the corpus, or beats the naive scan by < {NAIVE_MIN_SPEEDUP:.0f}×), "
            f"F4 (reload ≥ {LOAD_CEIL:.0%} of build), or F5 (native ≥ {CENTO_NATIVE_CEIL} bits/byte or ratio < "
            f"{CENTO_RATIO_FLOOR:.0f}×) each abort the mint. Harness: `bench/codex/scale.zig`; "
            "source: `src/corpus/index/codex/`."
        ),
        END,
    ]
    return "\n".join(lines) + "\n"


def splice(cert: Path, section: str) -> None:
    """Replace the marked codex block if present, else append it at EOF."""
    text = cert.read_text() if cert.exists() else "# gist — Dominance-and-Fit Certificate\n\n"
    lo, hi = text.find(START), text.find(END)
    if lo != -1 and hi != -1 and hi > lo:
        text = text[:lo] + section + text[hi + len(END) :].lstrip("\n")
        if not text.endswith("\n"):
            text += "\n"
    else:
        text = text.rstrip() + "\n\n" + section
    cert.write_text(text)


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(description="gist Layer F (codex self-index) certificate report")
    ap.add_argument("--certificate", type=Path, required=True)
    ap.add_argument("--scale", type=Path, required=True, help="codex-scale scale.jsonl")
    ap.add_argument("--compressors", type=Path, required=True, help="compressors.jsonl baselines")
    ap.add_argument("--csv", type=Path, required=True, help="sidecar codex.csv to emit")
    ap.add_argument("--machine", default="?")
    ap.add_argument("--zig", default="?")
    args = ap.parse_args()

    if not args.scale.exists():
        print(f"certify_codex_report: missing {args.scale}")
        return 1
    try:
        section = render(args.scale, args.compressors, args.machine, args.zig, args.csv)
    except Fail as exc:
        print(f"certify_codex_report: LAYER F INVARIANT VIOLATED — {exc}")
        return 1
    splice(args.certificate, section)
    print(f"wrote Layer F (codex) → {args.certificate}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
