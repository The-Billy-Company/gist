#!/usr/bin/env python3
"""gist certify — scanner-mode + conformance post-processor (Layer I, no index).

THE CLAIM THIS LAYER EXISTS TO SETTLE
    "ripgrep is more mature, and a scanner by design" — the insinuation being
    that gist only wins because it carries a trigram index, and that stripped
    of it, on ripgrep's own home turf of a live walk-read-scan, gist loses.

    So this layer never times the index. Its subject is `gist --no-index` with
    `GIST_NO_AUTOSERVE=1`: no persisted index, no crest sidecar, no resident
    daemon — a fresh process that walks, reads, and scans exactly like ripgrep,
    over exactly ripgrep's corpus scope. The `idx` column is shown only so the
    reader can see what the index adds ON TOP; it is never the subject of a
    verdict here.

    `bench/races/scanner_headtohead.sh` produces the samples, INTERLEAVED
    round-robin rather than block-per-tool, because ~10 coworking agents share
    this machine and a load excursion inside one tool's block would confound
    "which tool is faster" with "which moment was busier".

THE STATISTIC (identical to Layer A / the warm tier — defined once)
    `stats.py`: a 95% bootstrap-CI median (10k resamples, seeded) plus a
    tie-corrected two-sample Mann-Whitney U. A class is a WIN only when the
    scanner's median is lower AND p < alpha; overlap is PARITY; significantly
    slower is a LOSS. Nothing is averaged into a win — every class is printed.

MATURITY IS MEASURED HERE TOO, NOT ASSERTED
    Three independent conformance denominators fold into the same section, each
    scored against LIVE ripgrep as the oracle:

      flag surface   `bench/conformance/rgsuite/surface.py --json` — every flag
                     ripgrep's own `--generate complete-bash` + man page
                     document, probed byte-for-byte. Includes the adverse
                     undo-pair lane, where a negation that silently no-ops is
                     caught.
      mined suite    `bench/conformance/rgsuite/run.py`'s results.json —
                     ripgrep's own integration tests, replayed against both.
      differential   `bench/conformance/rgsuite/fuzz.py --json` — randomized
      fuzz           (pattern x flags x corpus) triples.

    The first two denominators are ripgrep's, which is their strength and their
    ceiling: a curated denominator holds only cases someone already thought of.
    The fuzz lane is the one that can still find something, so it is the one
    whose result is least safe to omit.

FAIL-CLOSED
    Refuses to splice and exits non-zero on: any class where the scanner is
    significantly slower than rg, any undeclared conformance divergence,
    rejection, unprobed value-taking flag, failing undo pair, mined FAIL, a
    conformance percentage below the committed baseline, or a fuzz residual that
    grew — in total or in any one class — or that holds a class the committed
    baseline does not name.

    `--fuzz` is MANDATORY, and that is the point of it. The lane used to be
    optional while any divergence was an outright refusal, which left "omit the
    lane" as the only way a real run could mint: the certificate then published
    two 100% figures and printed the fuzz command in its own reproduce block
    without ever carrying that command's result. A residual is now reportable,
    per class and shrink-only, so the honest outcome and the mintable one are
    the same outcome.

stdlib only. Deterministic: the bootstrap RNG is seeded (shared with stats).
"""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
import random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from stats import ALPHA, SEED, dominance, load_times_ms, median_ci, quantile  # noqa: E402

START = "<!-- SCANNER-LAYER-START -->"
END = "<!-- SCANNER-LAYER-END -->"
HEADER = "## Layer I — scanner mode + ripgrep conformance (no index)"
CONFORMANCE_ANCHOR = "### rg flag-surface conformance"
REPRODUCE_ANCHOR = "<details><summary>reproduce Layer I</summary>"
VERDICT_GLYPH = {"win": "✅ win", "parity": "≈ parity", "loss": "❌ loss"}
LANE_LABEL = {"list": "`-l`", "count": "`-c`"}

# Constant, measurement-free, and therefore refreshed by BOTH mint paths. It used
# to be emitted only by the full mint, which meant the block naming the commands
# outlived two directory renames and kept citing `bench/rgsuite/` after the tree
# had moved — a reproduce block that cannot be reproduced. The `--conformance-only`
# path rewrites it for the same reason it rewrites the evidence above it.
REPRODUCE_BLOCK = (
    REPRODUCE_ANCHOR,
    "",
    "```bash",
    'bash bench/dominance/races/scanner.sh                 # SCANNER_LANES="list count"',
    "python3 bench/conformance/rgsuite/surface.py --json .local/gist-compete/surface.json",
    "python3 bench/conformance/rgsuite/run.py              # writes rgsuite/results.json",
    "python3 bench/conformance/rgsuite/fuzz.py --iterations 6000 --seed 20260727 \\",
    "    --json .local/gist-compete/fuzz.json \\",
    "    --publish-baseline bench/conformance/rgsuite/fuzz_baseline.json   # the residual above",
    "```",
    "",
    "</details>",
)


def _load(results_dir: Path, cls: str, cell: str) -> list[float]:
    """Per-run times (ms) for one (class, cell), or [] when the cell was not timed."""
    path = results_dir / f"{cls}__{cell}.json"
    if not path.exists():
        return []
    try:
        return load_times_ms(path)
    except json.JSONDecodeError, KeyError, IndexError:
        return []


def _geomean(vals: list[float]) -> float:
    xs = [v for v in vals if v and v > 0]
    return math.exp(sum(map(math.log, xs)) / len(xs)) if xs else 0.0


def _lane(cell_id: str) -> tuple[str, str]:
    """Split a race cell id into (class, lane) — the `-count` suffix names the lane."""
    return (cell_id[: -len("-count")], "count") if cell_id.endswith("-count") else (cell_id, "list")


# ── the scanner table ─────────────────────────────────────────────────────────
def scanner_rows(
    results_dir: Path, order: list[tuple[str, str, str]], rng: random.Random
) -> tuple[list[str], list[list], dict[str, int], dict[str, list[float]]]:
    """Render one markdown row per timed class; return (lines, csv rows, tally, paired medians)."""
    lines = [
        "| class | lane | pattern | gist --no-index ms (95% CI) | rg ms (95% CI) | speedup | p | verdict | +index ms |",
        "|---|:--|---|--:|--:|--:|--:|:--|--:|",
    ]
    rows: list[list] = [
        [
            "class",
            "lane",
            "pattern",
            "noindex_ms",
            "noindex_ci_lo",
            "noindex_ci_hi",
            "rg_ms",
            "rg_ci_lo",
            "rg_ci_hi",
            "idx_ms",
            "speedup_vs_rg",
            "p",
            "verdict",
        ]
    ]
    tally = {"win": 0, "parity": 0, "loss": 0}
    paired: dict[str, list[float]] = {"noidx": [], "rg": [], "idx": []}

    for cell_id, _kind, pattern in order:
        noidx = _load(results_dir, cell_id, "noidx")
        rg = _load(results_dir, cell_id, "rg")
        if not noidx or not rg:
            continue
        cls, lane = _lane(cell_id)
        n_med, n_lo, n_hi = median_ci(noidx, rng)
        r_med, r_lo, r_hi = median_ci(rg, rng)
        d = dominance(noidx, rg)
        tally[d.verdict] += 1
        idx = _load(results_dir, cell_id, "idx")
        i_med = quantile(sorted(idx), 0.50) if idx else 0.0
        p_str = "<0.001" if d.p < 0.001 else f"{d.p:.3f}"
        lines.append(
            f"| `{cls}` | {LANE_LABEL[lane]} | `{pattern}` | {n_med:.1f} ({n_lo:.1f}-{n_hi:.1f}) "
            f"| {r_med:.1f} ({r_lo:.1f}-{r_hi:.1f}) | {d.speedup:.2f}x | {p_str} "
            f"| {VERDICT_GLYPH[d.verdict]} | {i_med:.1f} |"
        )
        rows.append(
            [
                cls,
                lane,
                pattern,
                f"{n_med:.3f}",
                f"{n_lo:.3f}",
                f"{n_hi:.3f}",
                f"{r_med:.3f}",
                f"{r_lo:.3f}",
                f"{r_hi:.3f}",
                f"{i_med:.3f}",
                f"{d.speedup:.3f}",
                f"{d.p:.4f}",
                d.verdict,
            ]
        )
        paired["noidx"].append(n_med)
        paired["rg"].append(r_med)
        if idx:
            paired["idx"].append(i_med)
    return lines, rows, tally, paired


# ── the conformance block ─────────────────────────────────────────────────────
def _mined(path: Path) -> dict[str, int] | None:
    """Bucket tally from `run.py`'s results.json (its own PASS/ORDER/FAIL vocabulary)."""
    try:
        recs = json.loads(path.read_text())
    except OSError, json.JSONDecodeError:
        return None
    tally: dict[str, int] = {}
    for r in recs:
        tally[r.get("bucket", "?")] = tally.get(r.get("bucket", "?"), 0) + 1
    return tally


def conformance_block(surface: dict | None, mined: dict[str, int] | None, fuzz: dict | None) -> tuple[list[str], int]:
    """Render the maturity evidence; return (lines, hard_failure_count)."""
    lines: list[str] = []
    bad = 0
    if surface:
        holes = surface["divergent"] + surface["rejected"] + surface["unprobed"]
        adverse_bad = surface.get("adverse_total", 0) - surface.get("adverse_passed", 0)
        bad += holes + adverse_bad
        lines += [
            "",
            "### rg flag-surface conformance",
            "",
            (
                f"_Denominator is ripgrep's, not ours: {surface['denominator']} documented flags "
                f"(long + short) read at run time from {surface['denominator_source']} against "
                f"{surface['rg_version']}. Each flag is exercised on a fixed miniature tree and "
                "both binaries' stdout + exit code are compared byte-for-byte._"
            ),
            "",
            "| outcome | count | what it means |",
            "|---|--:|---|",
            f"| identical | {surface['identical']} | byte-identical stdout and equal exit code |",
            (
                f"| declared boundary | {surface['boundary']} | differs only where gist names "
                "itself or extends rg (own palette, superset type registry, own identity) — each "
                "row carries a residual check verified this run |"
            ),
            f"| divergent | {surface['divergent']} | differs for no declared reason — a bug |",
            f"| rejected | {surface['rejected']} | gist does not accept the flag — a hole |",
            f"| unprobed | {surface['unprobed']} | value-taking flag with no declared probe value |",
            "",
            (
                f"**conformance = (identical + declared boundary) / documented = "
                f"{surface['conformance_pct']:.1f}%** "
                f"· adverse undo pairs {surface.get('adverse_passed', 0)}/"
                f"{surface.get('adverse_total', 0)} agree with rg."
            ),
            "",
            (
                "> The undo-pair lane is the half a per-flag probe cannot reach. Most negations "
                "name the default, so a negation that silently no-ops looks correct in isolation; "
                "each pair therefore places the negation after the positive flag it undoes, on a "
                "fixture where the two answers differ — `-uu --no-hidden` must stop finding the "
                "hidden file. ripgrep is the oracle for every pair; none of them is a hand-written "
                "expectation."
            ),
        ]
    if mined:
        inscope = mined.get("PASS", 0) + mined.get("ORDER", 0) + mined.get("FAIL", 0)
        passing = mined.get("PASS", 0) + mined.get("ORDER", 0)
        bad += mined.get("FAIL", 0)
        pct = 100.0 * passing / inscope if inscope else 0.0
        na = mined.get("NA", 0)
        lines += [
            "",
            "### ripgrep's own integration suite, replayed",
            "",
            (
                f"_ripgrep's `tests/` corpus mined into replayable records and driven through both "
                f"binaries on byte-identical fixtures ({sum(mined.values())} cases). "
                f"**{passing}/{inscope} = {pct:.1f}%** of the supported surface matches; "
                f"{mined.get('FAIL', 0)} FAIL. {na} cases are NA — gist's documented engine "
                "declines (a construct outside its guaranteed-linear syntax, where it exits 2 "
                "pointing at `-P`) plus the two ignore sources it deliberately does not read._"
            ),
        ]
    if fuzz:
        lines += fuzz_block(fuzz)
    return lines, bad


# ── the residual: the tail a curated denominator cannot see ───────────────────
KLASS_MEANING = {
    "line-count": "one output holds lines the other does not",
    "line-content": "same number of lines, one line's bytes differ",
    "trailing-bytes": "lines agree; the trailing terminator does not",
    "exit-code": "byte-identical output, different exit code",
    "timeout-gist": "gist hit the per-child wall where rg finished",
    "timeout-rg": "**rg** hit the wall where gist finished — not a gist failure",
    "crash-gist": "gist died on a signal",
    "crash-rg": "rg died on a signal",
}
# `fuzz._klass` suffixes a shape with `+exit` when the exit codes disagree too.
KLASS_SUFFIX = {"+exit": ", and the exit codes disagree"}

# Oracle-side events: the ORACLE hit the wall or died where gist finished. They
# are reported, never ratcheted — on two independent grounds. They are not gist
# conformance failures (gist produced an answer; rg did not), and they are a
# function of what else this machine was doing, so a floor keyed on them would
# fail a mint for a load excursion. A gate that flakes gets switched off, and a
# gate that is off is worse for the certificate than one that is honest about
# its own denominator.
ORACLE_SIDE = ("timeout-rg", "crash-rg")


def oracle_side(klass: str) -> bool:
    return klass.startswith(ORACLE_SIDE)


def klass_meaning(klass: str) -> str:
    """Prose for one residual class, including the composed `<shape>+exit` forms.

    An unlabeled row in the certificate is a number without a claim, so this
    resolves the suffix rather than falling through to `unclassified` — the
    label has to survive the producer composing a new name out of old parts.
    """
    for suffix, tail in KLASS_SUFFIX.items():
        if klass.endswith(suffix):
            return KLASS_MEANING.get(klass[: -len(suffix)], "unclassified") + tail
    return KLASS_MEANING.get(klass, "unclassified")


def fuzz_block(fuzz: dict) -> list[str]:
    """Render the differential-fuzz lane INCLUDING its residual taxonomy.

    The certificate's older shape reported this lane only when it was empty,
    because the gate that read it treated any divergence as a refusal — so the
    single honest outcome of a lane designed to generate invocations nobody
    curated was to omit the lane. Reporting the residual, per class, is what
    makes the two 100% lanes above it readable as the scoped claims they are.
    """
    total = fuzz.get("residual_total", fuzz.get("divergences", 0))
    iters = fuzz.get("iterations", 0)
    residual = fuzz.get("residual", {})
    # Two different numbers, and conflating them is how a fuzz lane flatters
    # itself: `agree` is byte-identical stdout AND exit code, while the declared
    # boundaries and mutual rejections below are merely NOT divergences. Report
    # the strict one as agreement and let the reader add.
    agree = fuzz.get("agree", iters - total)
    agree_pct = 100.0 * agree / iters if iters else 0.0
    lines = [
        "",
        "### differential fuzz vs live ripgrep — and its residual",
        "",
        (
            f"_{iters} randomized (pattern x flags x corpus) triples, seed "
            f"{fuzz.get('seed', '?')}, over {fuzz.get('corpora', '?')} adversarial corpora "
            "(invalid UTF-8, NUL-bearing binary, CRLF, a 4 MiB single line, 100k-line files, "
            "deep nesting, symlink loops, unreadable files). Both binaries run on the same "
            "bytes; stdout and exit code must match after the same normalizations the mined "
            f"oracle applies. **{agree}/{iters} = {agree_pct:.2f}% are byte-identical.** Of the "
            f"remainder, {fuzz.get('declared', 0)} exercised a catalogued boundary whose residual "
            f"check passed this run, {fuzz.get('declined', 0)} hit a documented gist engine "
            f"decline, and {fuzz.get('both_reject', 0)} used a pattern both engines reject — "
            f"agreement on a rejection is agreement, so none of those is a divergence. That "
            f"leaves **{total} unresolved**, with {fuzz.get('crashes', 0)} abnormal exits._"
        ),
    ]
    if residual:
        oracle = {k: n for k, n in residual.items() if oracle_side(k)}
        mine = sum(n for k, n in residual.items() if not oracle_side(k))
        lines += [
            "",
            "| residual class | count | ratcheted | what the disagreement looks like |",
            "|---|--:|:--|---|",
            *(
                f"| `{k}` | {n} | {'—' if oracle_side(k) else 'yes'} | {klass_meaning(k)} |"
                for k, n in sorted(residual.items(), key=lambda kv: (-kv[1], kv[0]))
            ),
            "",
            (
                "> This is the tail, and it is carried here rather than rounded off. The two "
                "lanes above are 100% against denominators **ripgrep owns** — the flags it "
                "documents and the tests it wrote — and that is exactly their limit: a curated "
                "denominator can only contain cases someone already thought of. This lane "
                "generates invocations nobody wrote down, so it is the only one that can still "
                "find something, and a residual of zero here would mean the generator had "
                f"stopped being adversarial. **{mine}** of these are gist's, and that number is "
                "ratcheted shrink-only per class: it may fall, it may not rise, and a class not "
                "already in the committed baseline fails the mint even when the total went down."
            ),
        ]
        if oracle:
            named = ", ".join(f"`{k}` ({n})" for k, n in sorted(oracle.items()))
            lines += [
                "",
                (
                    f"> {named} is **not** ratcheted, and is not a gist failure: the ORACLE hit "
                    "the per-child wall or died where gist returned an answer. It stays in the "
                    "table because deleting it would be the same omission this section exists to "
                    "end, and out of the floor because it measures this machine's load rather "
                    "than gist's conformance — a gate that fails on a load excursion gets "
                    "switched off, and a gate that is off is worth less than one that is honest "
                    "about its own denominator."
                ),
            ]
    return lines


def render(
    results_dir: Path,
    order: list[tuple[str, str, str]],
    meta: dict,
    rng: random.Random,
    surface: dict | None,
    mined: dict[str, int] | None,
    fuzz: dict | None,
) -> tuple[str, list[list], int, dict[str, int]]:
    """Return (markdown section, CSV rows, hard failures, verdict tally)."""
    runs, warmup, roots = meta.get("runs", "?"), meta.get("warmup", "?"), meta.get("roots", "?")
    table, csv_rows, tally, paired = scanner_rows(results_dir, order, rng)

    lines = [
        START,
        HEADER,
        "",
        (
            "_ripgrep's home turf, entered without our advantage. The subject is `gist "
            "--no-index` with `GIST_NO_AUTOSERVE=1` — no persisted trigram index, no crest "
            "sidecar, no resident daemon — so every cell below is a fresh process doing a live "
            f"walk, read, and scan over the same roots ({roots}) under the same ignore scope "
            "ripgrep applies. The 12 classes and their `-l` argv are byte-identical to Layer A's, "
            "so a row here maps 1:1 onto the indexed row above it, and the `-c` lane repeats each "
            "one where no short-circuit is available and every candidate must be scanned whole.\n\n"
            f"Sampling is INTERLEAVED round-robin, {runs} rounds (+{warmup} warmup), not "
            "block-per-tool: ~10 coworking agents share this machine, and a load excursion inside "
            "one tool's block would confound the tool difference with the difference between two "
            "moments. Every cell is equivalence-checked against ripgrep's exact result set BEFORE "
            "it is timed — a timing number for a wrong answer is worse than no number. The "
            f"verdict is the certificate's own fail-closed statistic: a WIN needs a lower median "
            f"**and** Mann-Whitney p < {ALPHA:.2f}. The `+index ms` column is context only, never "
            "a subject: it is what the index adds on top of a scanner that already stands alone._"
        ),
        "",
        *table,
    ]

    total = sum(tally.values())
    lines += [
        "",
        (
            f"**gist --no-index vs ripgrep across {total} certified cells: "
            f"{tally['win']} win · {tally['parity']} parity · {tally['loss']} loss.**"
        ),
    ]
    gn, gr, gi = (_geomean(paired[k]) for k in ("noidx", "rg", "idx"))
    if gn > 0 and gr > 0:
        extra = f" · the index then takes it a further **{gn / gi:.1f}×**" if gi > 0 else ""
        lines += [
            "",
            f"Geomean: the scanner alone is **{gr / gn:.2f}× faster than ripgrep**{extra}.",
        ]
    if tally["loss"] == 0 and total > 0:
        lines += [
            "",
            (
                f"> No class is slower than ripgrep at p<{ALPHA:.2f} **with the index switched "
                "off**. The \"scanner by design\" claim is therefore not a claim about design but "
                "about implementation, and it does not survive measurement: gist's advantage is "
                "not the index, it is the walk, the read, and the scan. The index is additive on "
                "top of a scanner that already wins — which is why turning it off costs a factor, "
                "not the verdict."
            ),
        ]

    conf_lines, bad = conformance_block(surface, mined, fuzz)
    lines += conf_lines
    lines += ["", *REPRODUCE_BLOCK, "", END]
    return "\n".join(lines) + "\n", csv_rows, bad + tally["loss"], tally


def splice(cert: Path, section: str) -> None:
    """Replace the marked scanner block if present, else append it at EOF."""
    text = cert.read_text() if cert.exists() else "# gist — Dominance-and-Fit Certificate\n\n"
    lo, hi = text.find(START), text.find(END)
    if lo != -1 and hi != -1 and hi > lo:
        text = text[:lo] + section + text[hi + len(END) :].lstrip("\n")
    else:
        text = text.rstrip() + "\n\n" + section
    cert.write_text(text if text.endswith("\n") else text + "\n")


def splice_conformance(cert: Path, lines: list[str]) -> None:
    """Replace the maturity evidence, leaving the timed table above it untouched.

    A flag re-probe is minutes and a quiescent timing race is an hour on a machine
    ~10 agents share; re-rendering the whole layer to move a flag count would trade
    a clean measurement for a noisier one, which is a worse certificate. The
    reproduce block below the evidence carries no measurement, so it is rewritten
    rather than preserved — leaving it pinned is what let it rot past two renames.
    """
    text = cert.read_text()
    lo, hi = text.find(CONFORMANCE_ANCHOR), text.find(END)
    if lo == -1 or hi == -1 or hi < lo:
        raise SystemExit("certify_scanner_report: no conformance block to refresh — mint Layer I first")
    body = "\n".join((*lines, "", *REPRODUCE_BLOCK)).lstrip("\n")
    cert.write_text(text[:lo] + body + "\n\n" + text[hi:])


def ratchet(surface: dict | None, baseline: Path | None) -> int:
    """The conformance ratchet: a measured percentage may rise and may not fall."""
    floor = _read_json(baseline) if baseline else None
    if not (floor and surface):
        return 0
    want, got = floor.get("conformance_pct", 0.0), surface["conformance_pct"]
    if got + 1e-9 < want:
        print(f"certify_scanner_report: conformance regressed {want:.1f}% → {got:.1f}%")
        return 1
    return 0


def residual_ratchet(fuzz: dict, baseline: Path | None) -> int:
    """The residual ratchet: shrink-only, per class, with no new class admitted.

    Ratcheting the TOTAL alone would let a newly-introduced defect ride in under
    a fix that happened to remove the same number of failures elsewhere, so each
    class carries its own floor and an unlisted class is a refusal on its own —
    a new root cause is news even when the arithmetic improved.

    Oracle-side classes (`ORACLE_SIDE`) are excluded from the arithmetic on both
    sides, so the floor measures gist and nothing else.

    With no committed baseline the rule is the strict one (any residual refuses),
    so the ratchet can only ever be created deliberately, never defaulted into.
    """
    got = {k: n for k, n in fuzz.get("residual", {}).items() if not oracle_side(k)}
    total = sum(got.values())
    floor = _read_json(baseline) if baseline else None
    if floor is None:
        if total:
            why = (
                f"the baseline at {baseline} would not read"
                if baseline
                else "no committed residual baseline"
            )
            print(
                f"certify_scanner_report: {total} unresolved fuzz failure(s) and {why} — "
                f"fix them, or record the tail with --fuzz-baseline"
            )
        return 1 if total else 0

    want = {k: n for k, n in floor.get("residual", {}).items() if not oracle_side(k)}
    want_total = sum(want.values())
    bad = 0
    for klass, n in sorted(got.items()):
        allowed = want.get(klass)
        if allowed is None:
            print(f"certify_scanner_report: NEW residual class `{klass}` ({n}) — not in the baseline")
            bad += 1
        elif n > allowed:
            print(f"certify_scanner_report: residual `{klass}` grew {allowed} → {n}")
            bad += 1
    if total > want_total:
        print(f"certify_scanner_report: residual total grew {want_total} → {total}")
        bad += 1
    # Shrinkage is not a failure, but an un-refreshed baseline is a ratchet that
    # has stopped ratcheting — say so loudly enough that the floor gets lowered.
    if not bad and (total < want_total or set(want) - set(got)):
        print(
            f"certify_scanner_report: residual SHRANK {want_total} → {total} — "
            f"refresh the baseline in this PR so the floor follows the fix"
        )
    return bad


def _read_json(path: Path | None) -> dict | None:
    if path is None:
        return None
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"certify_scanner_report: cannot read {path}: {exc}", file=sys.stderr)
        return None


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(description="gist scanner-mode + conformance report (Layer I)")
    ap.add_argument("results_dir", type=Path, nargs="?", help="dir of ${class}__{noidx,idx,rg}.json")
    ap.add_argument("--certificate", type=Path, required=True)
    ap.add_argument("--csv", type=Path, help="required unless --conformance-only")
    ap.add_argument(
        "--conformance-only",
        action="store_true",
        help="re-splice just the flag/mined/fuzz evidence over the last minted timing table",
    )
    ap.add_argument("--order", type=Path, help="TSV: class<TAB>kind<TAB>pattern (default: <results_dir>/order.tsv)")
    ap.add_argument("--meta", type=Path, help="JSON: runs/warmup/roots (default: <results_dir>/meta.json)")
    ap.add_argument("--conformance", type=Path, help="surface.py --json record")
    ap.add_argument("--mined", type=Path, help="rgsuite run.py results.json")
    ap.add_argument("--fuzz", type=Path, required=True, help="fuzz.py --json record (mandatory: see FAIL-CLOSED)")
    ap.add_argument(
        "--conformance-baseline",
        type=Path,
        help="committed floor; a lower conformance_pct is a hard failure (the ratchet)",
    )
    ap.add_argument(
        "--fuzz-baseline",
        type=Path,
        help="committed residual floor; a grown or new residual class is a hard failure",
    )
    args = ap.parse_args()

    if args.conformance_only:
        surface, fuzz = _read_json(args.conformance), _read_json(args.fuzz)
        mined = _mined(args.mined) if args.mined else None
        if fuzz is None:
            print(f"certify_scanner_report: --fuzz {args.fuzz} is unreadable — the lane is mandatory")
            return 1
        if not (surface or mined):
            print("certify_scanner_report: --conformance-only needs at least one curated evidence record")
            return 1
        lines, bad = conformance_block(surface, mined, fuzz)
        bad += ratchet(surface, args.conformance_baseline)
        bad += residual_ratchet(fuzz, args.fuzz_baseline)
        if bad:
            print(f"certify_scanner_report: REFUSING to splice — {bad} conformance/robustness failure(s)")
            return 1
        splice_conformance(args.certificate, lines)
        print(f"scanner conformance re-spliced (timing table untouched) → {args.certificate}")
        return 0

    if args.results_dir is None or args.csv is None:
        ap.error("results_dir and --csv are required unless --conformance-only")
    order_path = args.order or args.results_dir / "order.tsv"
    meta_path = args.meta or args.results_dir / "meta.json"
    # order.tsv is append-per-class, so a second race writing the same output dir
    # leaves a class listed twice — and a duplicated row would render the same
    # samples as two independent cells, inflating the win count. The race now
    # takes an exclusive lock; this dedupe means a pre-lock artifact still
    # reports one verdict per cell instead of quietly double-counting.
    order, seen = [], set()
    for ln in order_path.read_text().splitlines():
        if ln.strip():
            name, kind, pattern = ln.split("\t", 2)
            if name not in seen:
                seen.add(name)
                order.append((name, kind, pattern))
    meta = json.loads(meta_path.read_text())

    surface = _read_json(args.conformance)
    fuzz = _read_json(args.fuzz)
    mined = _mined(args.mined) if args.mined else None
    if fuzz is None:
        print(f"certify_scanner_report: --fuzz {args.fuzz} is unreadable — the lane is mandatory")
        return 1

    rng = random.Random(SEED)
    section, csv_rows, bad, tally = render(args.results_dir, order, meta, rng, surface, mined, fuzz)
    if len(csv_rows) <= 1:
        print("certify_scanner_report: no scanner cells — did scanner_headtohead.sh run?")
        return 1

    bad += ratchet(surface, args.conformance_baseline)
    bad += residual_ratchet(fuzz, args.fuzz_baseline)

    if bad:
        # Name the cells. A gate that refuses without saying WHICH cell lost
        # leaves the operator re-deriving the medians by hand, and the loss is
        # the whole reason to read the message.
        for r in csv_rows[1:]:
            if r[-1] == "loss":
                print(
                    f"certify_scanner_report:   loss  {r[0]} ({r[1]}) `{r[2]}`  "
                    f"noidx {r[3]}ms [{r[4]}-{r[5]}] vs rg {r[6]}ms [{r[7]}-{r[8]}]  p={r[11]}"
                )
        print(
            f"certify_scanner_report: REFUSING to splice — {tally['loss']} class loss vs rg, "
            f"{bad - tally['loss']} conformance/robustness failure(s)"
        )
        return 1

    splice(args.certificate, section)
    with args.csv.open("w", newline="") as fh:
        csv.writer(fh, lineterminator="\n").writerows(csv_rows)
    print(
        f"scanner layer: {len(csv_rows) - 1} cells · {tally['win']} win · "
        f"{tally['parity']} parity · {tally['loss']} loss → {args.certificate}"
    )
    print(f"scanner CSV → {args.csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
