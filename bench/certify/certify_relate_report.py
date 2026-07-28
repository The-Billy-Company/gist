#!/usr/bin/env python3
"""gist certify — Layer G report (the relate face: retrieval by description length).

Reads the results TSV `certify_relate.sh` emits (one row per checked claim) and
splices a self-contained **Layer G** section into CERTIFICATE.md between stable
sentinels, idempotent across re-mints.

Layer G is deliberately **not a dominance claim**. relate answers a question
exact search cannot — "which files would DESCRIBE this text most cheaply?" — so
it inherits nothing from Layer A and is certified on what it actually promises: a
retrieval-quality contract plus the boundary that defines its territory. Four
fail-closed claims, any violation aborts the mint:

  G1 BOUNDARY     every paraphrase finds 0 hits under exact `gist -F` (the class
                  is provably outside exact search — this is why relate exists).
  G2 RECALL@1     relate ranks the planted source top-1 for every paraphrase.
  G3 PACK         `relate pack` returns BOTH planted sources for a two-topic query.
  G4 SHORT RECALL relate recalls the single 3-byte planted needle.

stdlib only.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

START = "<!-- RELATE-LAYER-START -->"
END = "<!-- RELATE-LAYER-END -->"
HEADER = "## Layer G — relate (retrieval by description length, not pattern)"


class Fail(Exception):
    """A Layer-G invariant did not hold — refuse to splice."""


def _read(res: Path) -> list[tuple[str, str, str, str, bool]]:
    rows = []
    for line in res.read_text().splitlines():
        if not line.strip():
            continue
        claim, detail, want, got, ok = line.split("\t")
        rows.append((claim, detail, want, got, ok == "yes"))
    return rows


def render(res: Path, meta: dict, csv_out: Path) -> str:
    rows = _read(res)
    if not rows:
        raise Fail("no relate results — did the driver run?")

    def group(name: str) -> list[tuple[str, str, str, str, bool]]:
        return [r for r in rows if r[0] == name]

    recall, boundary, pack, short = (group(k) for k in ("recall", "boundary", "pack", "short"))
    if not recall:
        raise Fail("no recall rows")
    if not boundary:
        raise Fail("no boundary rows")
    if not pack:
        raise Fail("no pack row")
    if not short:
        raise Fail("no short-recall row")

    # ── G1 boundary ──────────────────────────────────────────────────────────
    leaked = [d for c, d, _, _, ok in boundary if not ok]
    if leaked:
        raise Fail("paraphrase exact-matched (corpus/boundary bug) at: " + ", ".join(leaked))

    # ── G2 recall@1 ──────────────────────────────────────────────────────────
    misses = [f"{d} (got {got}, want {want})" for _, d, want, got, ok in recall if not ok]
    if misses:
        raise Fail("relate recall@1 missed: " + "; ".join(misses))

    # ── G3 pack ──────────────────────────────────────────────────────────────
    if not pack[0][4]:
        raise Fail(f"relate pack did not return both sources ({pack[0][2]})")

    # ── G4 short recall ──────────────────────────────────────────────────────
    if not short[0][4]:
        raise Fail(f"relate short recall missed the 3-byte needle (got {short[0][3]})")

    with csv_out.open("w") as fh:
        fh.write("claim,detail,want,got,ok\n")
        for c, d, want, got, ok in rows:
            fh.write(f"{c},{d},{want},{got},{int(ok)}\n")

    count = meta.get("count", "?")
    n_q = len(recall)
    lines = [
        START,
        HEADER,
        "",
        (
            "_relate answers what exact search cannot: **which files would describe this text "
            "most cheaply?** — retrieval by conditional description length (a persisted trigram "
            "codebook nominates, a bounded suffix-automaton cross-parse decides). It is not the "
            "Layer-A query, so it inherits no dominance claim; this layer certifies what relate "
            "promises — a retrieval-quality contract and the boundary that defines its territory. "
            "Corpus is synthetic + deterministic; queries are **paraphrases** of planted files, "
            "reworded so they appear verbatim in no file. **Fail-closed**: any missed claim aborts "
            "the mint._"
        ),
        "",
        f"- corpus: **{count}** deterministic files · **{n_q}** paraphrase queries · driver `bench/certify/certify_relate.sh`",
        "",
        "| claim | check | result |",
        "|---|---|:--:|",
        f"| **G1 boundary** | every paraphrase → 0 hits under exact `gist -F` | ✓ ({len(boundary)}/{len(boundary)}) |",
        f"| **G2 recall@1** | relate ranks the planted source top-1 | ✓ ({n_q}/{n_q}) |",
        "| **G3 pack** | `relate pack` returns both planted sources | ✓ |",
        "| **G4 short recall** | relate recalls the 3-byte planted needle | ✓ |",
        "",
        (
            "> The boundary is the point: for every paraphrase, `gist -F` (and any exact scanner) "
            "returns **nothing** — the sentence exists in no file — while relate ranks the true "
            "source first. This is not gist losing; it is a different question, and relate is the "
            "only face that answers it. Driver + corpus: `bench/certify/certify_relate.sh`; engine: "
            "`src/exec/retrieval/retrieval.zig`."
        ),
        END,
    ]
    return "\n".join(lines) + "\n"


def splice(cert: Path, section: str) -> None:
    """Replace the marked relate block if present, else append it at EOF."""
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
    ap = argparse.ArgumentParser(description="gist Layer G (relate) certificate report")
    ap.add_argument("results", type=Path, help="results.tsv from certify_relate.sh")
    ap.add_argument("--certificate", type=Path, required=True)
    ap.add_argument("--csv", type=Path, required=True, help="sidecar relate.csv to emit")
    ap.add_argument("--meta", type=Path)
    args = ap.parse_args()

    meta = json.loads(args.meta.read_text()) if args.meta and args.meta.exists() else {}
    if not args.results.exists():
        print(f"certify_relate_report: missing {args.results}")
        return 1
    try:
        section = render(args.results, meta, args.csv)
    except Fail as exc:
        print(f"certify_relate_report: LAYER G INVARIANT VIOLATED — {exc}")
        return 1
    splice(args.certificate, section)
    print(f"wrote Layer G (relate) → {args.certificate}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
