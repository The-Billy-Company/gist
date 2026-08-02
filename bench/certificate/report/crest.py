#!/usr/bin/env python3
"""gist certify — Layer E report (the crest sieve, the trigram blind spot).

Reads the `crest.csv` emitted by `zig build crest` (the production proof harness,
`bench/crest/bench.zig`) and splices a self-contained **Layer E** section into
CERTIFICATE.md between stable sentinel markers, idempotent across re-mints.

Layer E is the one place gist's index math is new rather than borrowed: the
crest sieve (`src/kernel/math/crest.zig`, theorem in
`research/crest/PROOF.md`) prunes the literal-free class-repetition patterns
(`[0-9a-f]{12}`, `[0-9]{6}`) that every trigram-family index concedes — exactly
the `regex-classcount` row where Layer A measures cand% = 100% (the whole corpus
admitted). The harness is fail-closed (`matched ⇒ ¬pruned` against the
production matcher over the whole corpus + four-mode randomized adversarial
sweeps); this
section is spliced only when it exits 0, so a spliced Layer E *is* the soundness
receipt. RUN is the sieve (longest per-class run); CNT is the weaker
count-cousin at the same forced bound, carried to prove the run — not the
population — is the right necessary condition.

stdlib only.
"""

import argparse
import csv
import math
from pathlib import Path

START = "<!-- CREST-LAYER-START -->"
END = "<!-- CREST-LAYER-END -->"
HEADER = "## Layer E — crest sieve (the trigram blind spot, measured)"

# A class-repetition whose crest sieve prunes < this fraction is "wide": its
# forced run is too short to sieve, so it should prune ~nothing (an honest null,
# never a win). Narrow classes prune tens of percent; the gap is unambiguous.
WIDE_PRUNE_CEIL = 5.0


def _f(s: str) -> float | None:
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def _geomean(vals: list[float]) -> float:
    xs = [v for v in vals if v and v > 0]
    return math.exp(sum(map(math.log, xs)) / len(xs)) if xs else 0.0


def _read_csv(path: Path) -> tuple[list[dict], str, str]:
    """Return (rows, corpus_files, corpus_mib); the leading `# k\tv` pair carries corpus size."""
    files = mib = "?"
    body: list[str] = []
    for i, raw in enumerate(path.read_text().splitlines()):
        if raw.startswith("#"):
            fields = raw.lstrip("# ").split("\t")
            if i == 1 and len(fields) == 2:
                files, mib = fields[0].strip(), fields[1].strip()
            continue
        body.append(raw)
    return list(csv.DictReader(body, delimiter="\t")), files, mib


def render(rows: list[dict], files: str, mib: str, machine: str, zig: str) -> str:
    """Render the Layer E markdown section from the crest.csv rows."""
    lines = [
        START,
        HEADER,
        "",
        (
            "_The one place gist's index math is new rather than borrowed: the **crest "
            "sieve** (`src/kernel/math/crest.zig`, theorem in `research/crest/PROOF.md`). "
            "`zig build crest` links the **real** engine, builds the production crest sidecar, "
            "and walks the real corpus. It is **fail-closed**: for every file "
            "`matched ⇒ ¬pruned` against the production `Regex.docMatch`, over the fixed slate "
            "plus randomized adversarial `(pattern, file)` pairs in all four alphabet × case modes — a single "
            "false negative exits non-zero, so a spliced Layer E is itself the soundness receipt. "
            "These are the literal-free class-repetition patterns the trigram index prunes 0% on "
            "(Layer A `regex-classcount`, cand% = 100%). **RUN** is the sieve (longest per-class "
            "run); **CNT** is the weaker count-cousin at the same forced bound ĝ, carried to prove "
            "the run — not the population — is the right necessary condition. Lower `sieve ms` is "
            "better; same matcher both sides, so the speedup is purely avoided work._"
        ),
        "",
        f"- machine: **{machine}** · zig `{zig}` · corpus {files} files · {mib} MiB",
        "- sidecar: 8 byte-classes · 16 bytes/file · built by the same parallel pass `gist index` persists as `crest.bin`",
        "",
        "| query | pattern | RUN prune% | CNT prune% (cousin) | full ms | sieve ms | speedup |",
        "|---|---|--:|--:|--:|--:|--:|",
    ]

    narrow_speed: list[float] = []
    narrow_run: list[float] = []
    narrow_cnt: list[float] = []
    n_wide = 0
    for r in rows:
        run, cnt = _f(r["run_prune_pct"]), _f(r["cnt_prune_pct"])
        full, sieve, speed = _f(r["full_ms"]), _f(r["sieve_ms"]), _f(r["speedup"])

        def cell(v: float | None, unit: str = "") -> str:
            return f"{v:.1f}{unit}" if v is not None else "—"

        lines.append(
            f"| {r['query'].strip()} | `{r['pattern']}` | {cell(run, '%')} | {cell(cnt, '%')} "
            f"| {cell(full)} | {cell(sieve)} | {cell(speed, 'x')} |"
        )
        if run is not None and run < WIDE_PRUNE_CEIL:
            n_wide += 1
            continue
        if speed:
            narrow_speed.append(speed)
        if run is not None:
            narrow_run.append(run)
        if cnt is not None:
            narrow_cnt.append(cnt)

    g_speed = _geomean(narrow_speed)
    g_run = _geomean(narrow_run)
    g_cnt = _geomean(narrow_cnt)
    lines += [
        "",
        (
            f"**Narrow class-repetition slate ({len(narrow_speed)} patterns): the crest sieve prunes a "
            f"geomean {g_run:.0f}% of files the trigram index prunes 0% on, for a **{g_speed:.1f}× geomean "
            f"end-to-end speedup** — while the count-cousin at the same ĝ prunes only {g_cnt:.1f}%, the "
            f"gap that proves the run is the necessary condition.**"
        ),
        (
            f"The {n_wide} wide rows are kept honest: their forced run "
            "is too short to sieve, so crest correctly prunes ~nothing (≈1× — no manufactured win). In "
            "the shipped integration the win is larger still: a pruned doc's read is elided entirely "
            "(serial `IndexSkip` / parallel `Elide`), not just its match call."
        ),
        "",
        (
            "> Sound by construction — everything in ĝ rounds **down** (any construct the calculus "
            "cannot certify contributes nothing; unsafe caseless folds and non-ASCII Unicode classes "
            "decline to 0⃗), so under-pruning is the only failure mode. Theorem, min-of-max calculus over the AST, "
            "and the refereed priority review live in `research/crest/PROOF.md`; the harness is "
            "`bench/crest/bench.zig`."
        ),
        END,
    ]
    return "\n".join(lines) + "\n"


def splice(cert: Path, section: str) -> None:
    """Replace the one marked block and retire pre-marker duplicates."""
    text = cert.read_text() if cert.exists() else "# gist — Dominance-and-Fit Certificate\n\n"
    lo = text.find(START)
    if lo != -1:
        hi = text.find(END, lo + len(START))
        if hi == -1:
            raise ValueError("crest certificate has a start marker without an end marker")
        prefix = text[:lo]
        while (orphan_hi := prefix.rfind(END)) != -1 and (
            orphan_lo := prefix.rfind(HEADER, 0, orphan_hi)
        ) != -1:
            prefix = (
                prefix[:orphan_lo].rstrip() + "\n\n" + prefix[orphan_hi + len(END) :].lstrip("\n")
            )
        text = prefix + section + text[hi + len(END) :].lstrip("\n")
    else:
        text = text.rstrip() + "\n\n" + section
    if not text.endswith("\n"):
        text += "\n"
    cert.write_text(text)


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(description="gist Layer E (crest sieve) certificate report")
    ap.add_argument("--certificate", type=Path, required=True)
    ap.add_argument("--csv", type=Path, required=True)
    ap.add_argument("--machine", default="?")
    ap.add_argument("--zig", default="?")
    args = ap.parse_args()

    rows, files, mib = _read_csv(args.csv)
    if not rows:
        print("certify_crest_report: empty CSV — nothing to splice")
        return 1

    splice(args.certificate, render(rows, files, mib, args.machine, args.zig))
    print(f"wrote Layer E (crest) → {args.certificate}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
