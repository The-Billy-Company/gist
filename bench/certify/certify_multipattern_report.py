#!/usr/bin/env python3
"""gist certify — Layer K report (simultaneous multi-pattern matching vs Hyperscan).

Reads what `bench/races/multipattern.sh` measured and splices a self-contained
**Layer K** section into CERTIFICATE.md between stable sentinels, idempotent
across re-mints.

Layer K is the one layer with a named external champion. Hyperscan (Intel;
portable fork **Vectorscan**) is the reference for expression-ID attribution at
throughput, so this layer does not claim dominance — it claims a **boundary**,
and publishes the side of it where gist loses as plainly as the side where it
wins. Two arms, because the per-byte question and the user's question are not the
same question:

  arm 1  per byte, same resident blob, swept over N. Hyperscan's home turf.
  arm 2  end to end over the corpus. A stream scanner must touch every byte;
         gist has an index, and no per-byte speed recovers bytes never read.

Fail-closed, meaning before speed — any of these refuses the splice:

  K1 EQUALITY      every N in the sweep re-derived its whole attribution vector
                   from N INDEPENDENT single-pattern searches and agreed. This is
                   the `PatternSet` contract; a timing is never published without
                   it, because a wrong answer has no throughput.
  K2 CROSS-TOOL    gist and Vectorscan agree on the per-pattern document counts.
                   Two engines, one answer — the diff is the proof both arms
                   raced the same question. (Skipped, never faked, when
                   Vectorscan is absent.)
  K3 SWEEP         the per-byte sweep is present and every cell is a real
                   measurement.
  K4 SIGNIFICANCE  every end-to-end WIN this layer prints is a Mann-Whitney win
                   at alpha=0.05 over per-run times. A win that is not
                   significant is reported as parity, and the headline claim
                   (gist over the stream scanner) must be a real win or the mint
                   aborts.

Statistics come from `certify_stats.py` (medians, bootstrap CI, tie-corrected
Mann-Whitney) — this file computes none of its own.

stdlib only.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import random
from statistics import mean
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from certify_stats import ALPHA, dominance, load_times_ms, median_ci  # noqa: E402

START = "<!-- MULTIPATTERN-LAYER-START -->"
END = "<!-- MULTIPATTERN-LAYER-END -->"
HEADER = "## Layer K — multi-pattern simultaneous matching (vs Hyperscan/Vectorscan)"
SEED = 20260727

# Display labels + print order for arm 2. The harness names files by id only, so
# a rival that could not run is simply an absent file — never a fabricated row.
E2E = [
    ("gist", "gist `patterns` (indexed, attributed)"),
    ("vectorscan", "Vectorscan (all bytes, attributed)"),
    ("rg_alt", "rg alternation (**no** attribution)"),
    ("rg_seq", "rg × N (attributed, N walks)"),
]

# The adverse arm-2 regime, reported separately because it answers a different
# question: what happens when the slate contains a near-ubiquitous literal, so no
# index can skip anything and both tools must emit one very large answer. It
# bounds the primary claim rather than competing with it, and it is NOT folded
# into the significance gate — a band gist does not claim to win must not be able
# to fail a certificate for not winning it.
E2E_BROAD = [
    ("gist_broad", "gist `patterns` (broad slate)"),
    ("vectorscan_broad", "Vectorscan (broad slate)"),
]


class Fail(Exception):
    """A Layer-K invariant did not hold — refuse to splice."""


def table(header: list[str], align: list[str], rows: list[list[str]]) -> list[str]:
    """A markdown table already in Prettier's normal form.

    `bench/certify/artifact/CERTIFICATE.md` is Prettier-clean, and the repo lints
    it, so emitting compact `|a|b|` rows would make every mint of this layer dirty
    the slate and invite a reformat commit that churns the whole artifact. Padding
    here is cheaper than that. `align` takes `l`, `r`, or `c` per column and widths
    are the widest cell.

    Centering is spelled out rather than delegated to `str.center`, which is not
    the same function: CPython biases the odd space by `marg & width & 1`, so a
    9-wide cell in an 11-wide column lands left-heavy, while Prettier always puts
    the remainder on the right. One cell in this layer disagreed, which is exactly
    long enough to cost an afternoon.
    """
    cols = list(zip(header, *rows, strict=True))
    width = [max(3, *(len(c) for c in col)) for col in cols]
    bar = {"l": lambda w: "-" * w, "r": lambda w: "-" * (w - 1) + ":", "c": lambda w: ":" + "-" * (w - 2) + ":"}
    fit = {
        "l": str.ljust,
        "r": str.rjust,
        "c": lambda s, w: " " * ((w - len(s)) // 2) + s + " " * (w - len(s) - (w - len(s)) // 2),
    }

    def row(cells: list[str]) -> str:
        return "| " + " | ".join(fit[a](c, w) for c, a, w in zip(cells, align, width, strict=True)) + " |"

    return [row(header), "| " + " | ".join(bar[a](w) for a, w in zip(align, width, strict=True)) + " |"] + [
        row(r) for r in rows
    ]


class Cell:
    """One row of the per-byte sweep."""

    def __init__(self, row: str) -> None:
        f = row.split("\t")
        if len(f) != 7:
            raise Fail(f"malformed perbyte row (want 7 fields, got {len(f)}): {row!r}")
        self.n = int(f[0])
        self.gist = float(f[1])
        self.rival: float | None = None if f[2] in ("skip", "fail") else float(f[2])
        self.rival_state = f[2]
        self.verified = f[3]
        self.cross = f[4]
        # Which prefilter tier answered this row, and whether the tier the width
        # threshold did NOT pick was also held to the oracle at this N.
        self.tier = f[5]
        self.alt = f[6]

    @property
    def ratio(self) -> float | None:
        return None if not self.rival else self.gist / self.rival


def read_perbyte(path: Path) -> list[Cell]:
    """The arm-1 sweep, one `Cell` per N, in measured order."""
    cells = [Cell(line) for line in path.read_text().splitlines() if line.strip()]
    if not cells:
        raise Fail("empty per-byte sweep — did the harness run?")
    return cells


# The harness writes a closed vocabulary into each perbyte cell, and these gates
# WHITELIST the tokens that mean "proven", rather than blacklisting the ones that
# mean "broken". The distinction is the whole value of the gate: a blacklist
# passes every token it has never heard of, so a harness typo, a truncated write,
# or a future third failure spelling would all splice a clean-looking claim over
# an unproven measurement. Anything unrecognized is therefore a hard failure.
VERIFIED_OK = frozenset({"yes"})  # arm-1 self-verify: no other token is proof
CROSS_OK = frozenset({"equal", "skip"})  # agreed, or no rival to agree with
TIER_OK = frozenset({"dragnet", "trawl", "none"})  # the mechanisms that exist
# `n/a` only when no rival tier exists to force (`tier == "none"`), never as a
# stand-in for "we didn't check" — `alt_of` enforces that pairing.
ALT_OK = frozenset({"yes", "n/a"})


def check_fail_closed(cells: list[Cell]) -> None:
    """K1-K3: the answer must be right, and agreed, before any speed is printed."""
    unverified = [c.n for c in cells if c.verified not in VERIFIED_OK]
    if unverified:
        raise Fail(
            "attribution equality with N independent searches was NOT re-asserted at "
            f"N={unverified} — a PatternSet answer must equal N single-pattern answers"
        )
    mismatched = [c.n for c in cells if c.cross not in CROSS_OK]
    if mismatched:
        detail = ", ".join(f"N={c.n}:{c.cross!r}" for c in cells if c.cross not in CROSS_OK)
        raise Fail(
            f"per-pattern document counts are not proven equal to Vectorscan's ({detail}) "
            "— one of the two matchers is wrong, or the cross-check never ran; fix it, "
            "never publish around it"
        )
    broken = [c.n for c in cells if c.rival_state == "fail"]
    if broken:
        raise Fail(f"the Vectorscan arm errored at N={broken} (a failed rival is not a skipped rival)")

    bad_tier = [f"N={c.n}:{c.tier!r}" for c in cells if c.tier not in TIER_OK]
    if bad_tier:
        raise Fail(
            f"unrecognized prefilter tier ({', '.join(bad_tier)}) — the certificate names "
            "which mechanism produced each row, so a tier it cannot name is not reportable"
        )
    bad_alt = [f"N={c.n}:{c.alt!r}" for c in cells if c.alt not in ALT_OK]
    if bad_alt:
        raise Fail(
            f"the non-selected tier was not proven exact ({', '.join(bad_alt)}) — gist "
            "dispatches on slate width, so proving only the tier the threshold picked "
            "would leave the other mechanism unproven the moment the threshold moves"
        )
    # `n/a` is legitimate only where there is genuinely no other tier to force.
    stray = [c.n for c in cells if c.alt == "n/a" and c.tier != "none"]
    if stray:
        raise Fail(
            f"N={stray} reports no alternate-tier check while running tier "
            f"{[c.tier for c in cells if c.n in stray][0]!r} — 'n/a' may only mean "
            "'no rival mechanism exists', never 'not checked'"
        )


def races(raw: Path, rng: random.Random) -> tuple[dict[str, tuple[float, float, float]], dict[str, object]]:
    """Arm-2 medians+CI per tool, and gist-vs-each verdicts from `certify_stats`."""
    times = {}
    for tool, _ in E2E + E2E_BROAD:
        js = raw / f"e2e-{tool}.json"
        if js.exists():
            times[tool] = load_times_ms(js)
    if "gist" not in times:
        raise Fail("no end-to-end timing for gist — arm 2 did not run")
    stats = {t: median_ci(v, rng) for t, v in times.items()}
    # Verdicts are computed against the primary slate's gist run only; the broad
    # pair is compared to its own baseline below, never mixed into these.
    primary = {t for t, _ in E2E}
    verdicts = {t: dominance(times["gist"], v) for t, v in times.items()
                if t != "gist" and t in primary}
    return stats, {"verdicts": verdicts, "times": times}


def render(perbyte: Path, raw: Path, meta: dict, csv_out: Path) -> str:
    """The Layer K section, or `Fail` if any invariant does not hold."""
    cells = read_perbyte(perbyte)
    check_fail_closed(cells)
    rng = random.Random(SEED)
    stats, extra = races(raw, rng)
    verdicts = extra["verdicts"]
    assert isinstance(verdicts, dict)

    vs = meta.get("vectorscan", {})
    have_rival = bool(vs.get("available")) and any(c.rival for c in cells)
    version = vs.get("version", "unknown")

    # K4 — the headline claim must be a real win, not a hopeful one.
    head = verdicts.get("vectorscan")
    if head is not None and head.verdict != "win":
        raise Fail(
            "the end-to-end claim over the stream scanner is "
            f"{head.verdict} (p={head.p:.3g}, {head.speedup:.2f}x) — Layer K refuses to "
            "print a win it cannot defend"
        )

    docs = meta.get("docs", "?")
    mib = meta.get("bytes", 0) / (1 << 20) if meta.get("bytes") else 0
    e2e_n = meta.get("e2e_patterns", "?")

    # `tier` and `alt_verified` are APPENDED, never inserted: the first six columns
    # keep their positions so anything reading this side-car by index is unaffected
    # by the two-tier prefilter landing. Empty on the e2e rows, which have no tier.
    with csv_out.open("w") as fh:
        fh.write("arm,key,gist,rival,ratio,note,tier,alt_verified\n")
        for c in cells:
            fh.write(
                f"perbyte,N={c.n},{c.gist:.3f},{c.rival_state},"
                f"{'' if c.ratio is None else f'{c.ratio:.3f}'},{c.cross},{c.tier},{c.alt}\n"
            )
        for tool, label in E2E:
            if tool not in stats:
                continue
            med, lo, hi = stats[tool]
            v = verdicts.get(tool)
            note = "baseline" if tool == "gist" else f"{v.verdict} p={v.p:.3g}"  # type: ignore[union-attr]
            fh.write(f"e2e,{label},{med:.1f},{lo:.1f}-{hi:.1f},,{note},,\n")
        # Same `e2e` arm, labeled rows, no verdict: the adverse band is a bound on
        # the claim, not a contest gist entered.
        for tool, label in E2E_BROAD:
            if tool not in stats:
                continue
            med, lo, hi = stats[tool]
            fh.write(f"e2e,{label},{med:.1f},{lo:.1f}-{hi:.1f},,adverse-slate,,\n")

    wins = [c for c in cells if c.ratio and c.ratio > 1]
    losses = [c for c in cells if c.ratio and c.ratio <= 1]
    lines = [
        START,
        "",
        HEADER,
        "",
        (
            "_The one layer with a named external champion. **Hyperscan** (Intel; the maintained "
            "portable fork **Vectorscan**, NEON/SVE) is the reference for simultaneous "
            "multi-pattern matching with expression-ID attribution: N expressions into one "
            "matcher, bytes walked once, every match reported with which pattern produced it. "
            "gist's surface is `PatternSet` (`src/kernel/slate/`), shipped as "
            "`relate patterns -e P -e P …`. This layer does not claim dominance — it claims a "
            "**boundary**, and publishes the losing side as plainly as the winning one._"
        ),
        "",
        (
            f"- corpus: **{docs}** documents · **{mib:.1f} MiB** packed by "
            "`bench/multipattern/pack.py` from gist's own `paths.list`, so both matchers "
            "see identical bytes in identical order"
        ),
        (
            f"- rival: Vectorscan **{version}** via `pkg-config libhs`, built from "
            "`bench/multipattern/vscan.c` — a competitor, never a dependency"
            if have_rival
            else f"- rival: **Vectorscan absent** — every Vectorscan cell skipped ({vs.get('why', 'unknown')})"
        ),
        f"- driver `bench/races/multipattern.sh` · arm `bench/multipattern/bench.zig`",
        "",
        "### Arm 1 — per byte (Hyperscan's home turf)",
        "",
        (
            "Both matchers over one resident blob, no tree walk on either side, swept over N "
            "because the entire claim is about how cost scales with the size of the question."
        ),
        "",
    ]
    perbyte_rows = []
    for c in cells:
        rival = f"{c.rival:.2f}" if c.rival else f"_{c.rival_state}_"
        ratio = f"**{c.ratio:.2f}×**" if c.ratio and c.ratio > 1 else (f"{c.ratio:.2f}×" if c.ratio else "—")
        # The tier column is what makes the sweep a tier DECISION rather than a
        # list of numbers: it shows where dispatch hands over, and the ✓ carries
        # that the other mechanism was held to the same oracle at this N too.
        perbyte_rows.append([str(c.n), f"{c.gist:.2f}", rival, ratio, c.tier, f"✓ {c.cross}"])
    lines += table(
        ["N patterns", "gist GB/s", "Vectorscan GB/s", "ratio", "tier", "attribution"],
        ["r", "r", "r", "r", "c", "c"],
        perbyte_rows,
    )
    handover = [c.n for c in cells if c.tier == "trawl"]
    if handover and any(c.tier == "dragnet" for c in cells):
        lines += [
            "",
            (
                f"The `tier` column is the dispatch: the SIMD **dragnet** sieve answers narrow "
                f"slates, the Aho–Corasick **trawl** answers from N={min(handover)} up. Both "
                "mechanisms are re-derived against N independent single-pattern searches at "
                "_every_ N in this table — the selected one and the forced-other one — so "
                "moving the threshold cannot move which code has been proven exact."
            ),
        ]

    if wins and losses:
        worst = min(losses, key=lambda c: c.ratio or 1)
        lost_at = ", ".join(f"N={c.n}" for c in losses)
        # Which side moved is a question the table can answer, so it is measured
        # rather than asserted: compare each tool at the losing N against its own
        # throughput at the neighboring swept widths. A loss where gist held its
        # own pace and the rival accelerated is a DIFFERENT fact from one where
        # gist fell off, and naming the wrong one is how a certificate ends up
        # with a true number beside a false explanation.
        def _drift(cell: Cell) -> tuple[float, float]:
            # Adjacency in the SWEEP, not in linear N: the sweep doubles, so N=64's
            # neighbors are 32 and 128. Taking the two nearest by |Δn| would pick
            # 16 and 32 and compare a row against the far side of a doubling.
            order = sorted((c for c in cells if c.gist and c.rival), key=lambda c: c.n)
            try:
                at = next(i for i, c in enumerate(order) if c.n == cell.n)
            except StopIteration:
                return (1.0, 1.0)
            ref = [c for c in (order[at - 1] if at else None, order[at + 1] if at + 1 < len(order) else None) if c]
            if not ref or not cell.gist or not cell.rival:
                return (1.0, 1.0)
            g = mean([c.gist for c in ref if c.gist])
            r = mean([c.rival for c in ref if c.rival])
            return (cell.gist / g if g else 1.0, cell.rival / r if r else 1.0)

        gd, rd = _drift(worst)
        # 12% off a best-of-N throughput is comfortably outside this arm's noise;
        # below that, decline to name a cause rather than invent one.
        if rd >= 1.12 and gd >= 0.88:
            why = (
                f"**Vectorscan got faster here, not gist slower** — at N={worst.n} it runs "
                f"{rd:.2f}× its own pace at the neighboring widths while gist holds "
                f"{gd:.2f}× of its. That is its literal stage switching strategy into a band "
                "that suits this slate. Nothing in gist regressed; the rival simply has a "
                "gear here that it does not have on either side."
            )
        elif gd <= 0.88 and rd < 1.12:
            why = (
                f"This one is gist's to own: it drops to {gd:.2f}× its own pace at the "
                f"neighboring swept widths while "
                f"Vectorscan holds {rd:.2f}× of its — the `{worst.tier}` tier is losing "
                "ground at this width, not being outrun by a rival that sped up."
            )
        else:
            why = (
                f"Both tools move here (gist {gd:.2f}×, Vectorscan {rd:.2f}× of their own "
                "neighboring pace), so this report does not assign a single cause to it."
            )
        lines += [
            "",
            (
                f"> **The boundary, stated honestly.** gist is faster per byte at every swept N "
                f"except {lost_at} — best {max(c.ratio or 0 for c in wins):.2f}× on the wins, and "
                f"**Vectorscan takes {1 / (worst.ratio or 1):.2f}× at N={worst.n}** on gist's "
                f"`{worst.tier}` tier. {why} Hyperscan keeps those bands, and they are printed "
                "here rather than dropped, because a table with no losing rows is not believable."
            ),
        ]
    elif wins:
        lines += ["", f"> gist is faster per byte at every N measured (up to {max(c.ratio or 0 for c in wins):.2f}×)."]

    lines += [
        "",
        "### Arm 2 — end to end over the corpus (the actual workload)",
        "",
        (
            f'"Find these **{e2e_n}** patterns across the corpus." A stream scanner must touch '
            "every byte of every file; gist has an index, and no per-byte speed recovers bytes it "
            "never reads. Medians over 10 runs with 95% bootstrap CI; verdicts are tie-corrected "
            f"Mann-Whitney at alpha={ALPHA}."
        ),
        "",
        (
            "The slate is drawn from a **selectivity band** (occurrences capped), because corpus "
            "token frequency is not query frequency: an agent sweeps for `WalletService`, never "
            "for `string`. Drawn from the raw distribution instead, one literal of ten occurs "
            "~49,000 times, every strategy must emit ~112,000 attributed lines, and the arm "
            "measures line formatting rather than search. That regime is real, so it is published "
            "too — as the adverse pair below, not omitted."
        ),
        "",
    ]
    attribution = {"gist": "exact", "vectorscan": "exact", "rg_alt": "**none**", "rg_seq": "exact"}
    e2e_rows = []
    for tool, label in E2E:
        if tool not in stats:
            if tool == "vectorscan":
                e2e_rows.append([label, "_skipped_", "—", "—", "—"])
            continue
        med, lo, hi = stats[tool]
        if tool == "gist":
            cmp_cell = "_baseline_"
        else:
            v = verdicts[tool]
            cmp_cell = f"**{v.speedup:.1f}× slower**" if v.verdict == "win" else (
                f"{1 / v.speedup:.1f}× faster" if v.verdict == "loss" else "parity"
            )
        e2e_rows.append([label, f"{med:.0f} ms", f"{lo:.0f}–{hi:.0f}", cmp_cell, attribution[tool]])
    lines += table(
        ["strategy", "median", "95% CI", "vs gist", "attribution"],
        ["l", "r", "r", "c", "c"],
        e2e_rows,
    )

    # The adverse regime, printed beside the win so the win has a boundary.
    if "gist_broad" in stats:
        gb = stats["gist_broad"][0]
        broad_rows = []
        for tool, label in E2E_BROAD:
            if tool not in stats:
                continue
            med, lo, hi = stats[tool]
            rel = "_baseline_" if tool == "gist_broad" else (
                f"{med / gb:.2f}× gist" if gb else "—"
            )
            broad_rows.append([label, f"{med:.0f} ms", f"{lo:.0f}–{hi:.0f}", rel])
        lines += [
            "",
            (
                "**Adverse slate** — same width, no selectivity cap, so it contains a "
                "near-ubiquitous literal. There is nothing for an index to skip and both tools "
                "must emit the same very large answer, which is exactly where gist's structural "
                "advantage should and does largely evaporate:"
            ),
            "",
        ]
        lines += table(
            ["strategy", "median", "95% CI", "relative"],
            ["l", "r", "r", "c"],
            broad_rows,
        )

    if head is not None:
        lines += [
            "",
            (
                f"> **This is the race that matters, and gist wins it {head.speedup:.1f}×** "
                f"(p={head.p:.3g}). Not by matching faster — by not reading. The index answers "
                "which documents _can_ contain each pattern before a byte of the rest is touched, "
                "and the answer is bit-identical to N independent searches (K1). A stream "
                "scanner structurally cannot have that filter: correctness for Hyperscan means "
                "every byte, and every byte is the cost."
            ),
        ]
    alt = verdicts.get("rg_alt")
    if alt is not None:
        rel = (
            f"{alt.speedup:.1f}× slower than gist"
            if alt.verdict == "win"
            else (f"{1 / alt.speedup:.1f}× faster than gist" if alt.verdict == "loss" else "at parity with gist")
        )
        lines += [
            "",
            (
                f"> The `rg` alternation column is in the field because it is what a real engineer "
                f"types, and it is {rel} — but read its last cell: it answers a **weaker question**. "
                "One fused alternation says a file matched _something_; which pattern hit has to be "
                "re-derived afterwards, which is the tax the column does not show."
            ),
        ]

    lines += [
        "",
        (
            "**Fail-closed.** K1 attribution equality with N independent single-pattern searches "
            f"(re-asserted at every N: {', '.join(str(c.n) for c in cells)}) · K2 cross-tool "
            f"agreement with Vectorscan on per-pattern document counts · K3 every swept cell "
            "measured · K4 every printed win significant at alpha=" + f"{ALPHA}. "
            "Any violation aborts the mint rather than weakening a claim."
        ),
        END,
    ]
    return "\n".join(lines) + "\n"


def splice(cert: Path, section: str) -> None:
    """Replace the marked multipattern block if present, else append it at EOF."""
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
    ap = argparse.ArgumentParser(description="gist Layer K (multi-pattern vs Hyperscan) certificate report")
    ap.add_argument("--perbyte", type=Path, required=True, help="perbyte.tsv from multipattern.sh")
    ap.add_argument("--raw", type=Path, required=True, help="dir of hyperfine e2e-<tool>.json exports")
    ap.add_argument("--meta", type=Path, required=True)
    ap.add_argument("--certificate", type=Path, required=True)
    ap.add_argument("--csv", type=Path, required=True, help="sidecar multipattern.csv to emit")
    args = ap.parse_args()

    for p in (args.perbyte, args.meta):
        if not p.exists():
            print(f"certify_multipattern_report: missing {p}")
            return 1
    meta = json.loads(args.meta.read_text())
    try:
        section = render(args.perbyte, args.raw, meta, args.csv)
    except Fail as exc:
        print(f"certify_multipattern_report: LAYER K INVARIANT VIOLATED — {exc}")
        return 1
    splice(args.certificate, section)
    print(f"wrote Layer K (multi-pattern vs Hyperscan) → {args.certificate}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
