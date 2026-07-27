#!/usr/bin/env python3
"""gist certify — Layer L report (index quality head-to-head against csearch).

Reads the `indexq.tsv` emitted by `zig build indexq` (`bench/sieve/indexq.zig`)
and, optionally, the `indexcost.tsv` emitted by `bench/sieve/indexcost.sh`, and
splices a self-contained **Layer L** section into CERTIFICATE.md between stable
sentinel markers, idempotent across re-mints.

Layer L answers one claim and only that claim: *"your trigram index is
csearch-class, not better."* csearch (Google Code Search, Russ Cox 2012) is
gist's acknowledged trigram ancestor, and the honest axis for comparing two
indexes is not wall time — which confounds the index with the walk, the IO and
the matcher — but **filter quality**: candidate bytes admitted per query, and
the precision of what is admitted. The harness holds everything but the boolean
formula fixed (one corpus, one built index, one evaluator, one verifier) and
lifts csearch's own formula verbatim out of `csearch -verbose`, so the two
planners are compared and nothing else is.

**Fail-closed.** This reporter refuses to splice a win it cannot substantiate:

  * gist must admit **strictly fewer** candidate bytes than csearch in total
    over the measured slate;
  * gist must not **regress** on any single class (never admit more than
    csearch anywhere) — a total that hides a loss is not a win;
  * every arm must have verified the **same hit count** per class (the harness
    already exits non-zero otherwise; re-checked here so a stale TSV cannot
    launder an unsound run);
  * where `indexcost.tsv` is supplied, gist's index must be within
    `MAX_SIZE_RATIO` of csearch's and its build within `MAX_BUILD_RATIO` —
    selectivity bought with a pathologically bigger or slower index is not a
    better index.

Any of those failing exits non-zero and writes nothing.

stdlib only.
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

START = "<!-- INDEXQ-LAYER-START -->"
END = "<!-- INDEXQ-LAYER-END -->"
HEADER = "## Layer L — index quality head-to-head (vs csearch)"

# The cost envelope a selectivity win must stay inside to count as an index
# improvement rather than a trade. Generous on purpose: the point is to catch a
# pathological trade (a 4× index), not to litigate a few percent.
MAX_SIZE_RATIO = 1.10
MAX_BUILD_RATIO = 1.50

ARMS = ("gist-base", "gist", "csearch")


def read_tsv(path: Path) -> tuple[list[dict], dict[str, str]]:
    """Rows plus the `# k…\\n# v…` preamble pairs the harnesses write."""
    keys: list[str] = []
    meta: dict[str, str] = {}
    body: list[str] = []
    for raw in path.read_text().splitlines():
        if not raw.startswith("#"):
            body.append(raw)
            continue
        fields = [f.strip() for f in raw.lstrip("# ").split("\t")]
        if not keys:
            keys = fields
        else:
            meta = dict(zip(keys, fields))
            keys = []
    return list(csv.DictReader(body, delimiter="\t")), meta


def pct(x: float) -> str:
    return f"{x * 100:.2f}%"


def mib(n: float) -> str:
    return f"{n / (1 << 20):.0f}"


def verdict(g: dict, c: dict) -> str:
    """Per-class outcome, judged on candidate BYTES (the metric under test)."""
    gb, cb = int(g["cand_bytes"]), int(c["cand_bytes"])
    if gb < cb:
        return f"**gist −{(1 - gb / cb) * 100:.1f}%**"
    if gb > cb:
        return f"csearch −{(1 - cb / gb) * 100:.1f}%"
    return "tie"


def table(rows_by_class: dict[str, dict[str, dict]], classes: list[str]) -> list[str]:
    """One markdown table over the given classes, three arms per class."""
    out = [
        "| class | pattern-shape | gist-base cand% | **gist cand%** | csearch cand% | gist bytes | csearch bytes | gist prec. | csearch prec. | verdict |",
        "|---|---|--:|--:|--:|--:|--:|--:|--:|:--|",
    ]
    for cls in classes:
        a = rows_by_class[cls]
        b, g, c = a["gist-base"], a["gist"], a["csearch"]
        out.append(
            f"| `{cls}` | {g['kind']} "
            f"| {pct(float(b['cand_byte_frac']))} "
            f"| **{pct(float(g['cand_byte_frac']))}** "
            f"| {pct(float(c['cand_byte_frac']))} "
            f"| {mib(int(g['cand_bytes']))} MiB | {mib(int(c['cand_bytes']))} MiB "
            f"| {pct(float(g['precision']))} | {pct(float(c['precision']))} "
            f"| {verdict(g, c)} |"
        )
    return out


def totals(rows_by_class: dict[str, dict[str, dict]], classes: list[str]) -> dict[str, int]:
    return {
        arm: sum(int(rows_by_class[c][arm]["cand_bytes"]) for c in classes) for arm in ARMS
    }


# The Unicode row is carried, and named, rather than quietly dropped: gist's
# rg-parity default reads `\d` as `\p{Nd}` (~680 codepoints, past the planner's
# class ceiling) where csearch's Go `\d` is the ten ASCII digits. The ASCII
# spelling of the same probe is the like-for-like one, so both appear and the
# aggregate is taken over the DEFAULT flags a user actually runs.
ASCII_TWIN = "stress-isodate-ascii"


def production(rows: list[dict]) -> tuple[list[str], list[str]]:
    """(markdown lines, failures) for the wired-path measurement.

    Fail-closed on the only thing wiring can get wrong: production must never
    admit MORE than the pre-wiring flat OR on any class (that would mean the
    planner made the product worse), and it must narrow on at least one — a
    plan that never fires certifies nothing.
    """
    failures: list[str] = []
    default = [r for r in rows if r["class"] != ASCII_TWIN]
    narrowed = [r for r in default if int(r["cover_bytes"]) < int(r["flat_bytes"])]
    for r in default:
        if int(r["cover_bytes"]) > int(r["flat_bytes"]):
            failures.append(
                f"{r['class']}: the WIRED path admits {r['cover_bytes']} B vs the "
                f"pre-wiring {r['flat_bytes']} B — wiring made production worse"
            )
    if not narrowed:
        failures.append(
            "the wired path narrowed no class — the cover never reached production"
        )

    flat = sum(int(r["flat_bytes"]) for r in default)
    cover = sum(int(r["cover_bytes"]) for r in default)
    # Where the candidate set is byte-identical the planner cannot have changed
    # the work, so whatever wall-clock difference those rows show IS the run-to-
    # run noise of this machine. Publishing it beside the real speedup is what
    # keeps the real speedup honest.
    tied = [r for r in default if int(r["cover_bytes"]) == int(r["flat_bytes"])]
    speedup = _ratio(narrowed)
    floor = _ratio(tied)

    lines = [
        "",
        "### On the production query path (`bench/sieve/production.sh`)",
        "",
        (
            "_The head-to-head above measures a planner; this measures the **product**. "
            "Same binary in both arms — `GIST_NO_COVER=1` stands the cover down — so no "
            "build difference can be mistaken for a win. Candidate bytes are read out of "
            "`elide.assemble` AFTER the crest subtraction, i.e. the oracle's real final "
            "candidate set, and wall time is the whole process: argv, index load, plan, "
            "posting decode, walk, read, match, emit, exit._"
        ),
        "",
        "| class | flat-OR admits | **cover admits** | delta | flat wall | **cover wall** |",
        "|---|--:|--:|--:|--:|--:|",
    ]
    for r in rows:
        f, c = int(r["flat_bytes"]), int(r["cover_bytes"])
        delta = f"**−{(1 - c / f) * 100:.1f}%**" if c < f else "—"
        note = " _(ASCII twin)_" if r["class"] == ASCII_TWIN else ""
        lines.append(
            f"| `{r['class']}`{note} | {mib(f)} MiB | **{mib(c)} MiB** | {delta} "
            f"| {int(r['flat_us']) / 1000:.0f} ms | **{int(r['cover_us']) / 1000:.0f} ms** |"
        )
    lines += [
        "",
        (
            f"Over the {len(default)} classes at **default flags**, the wired path admits "
            f"**{cover / 1e6:.0f} MB where the pre-wiring prefilter admitted {flat / 1e6:.0f} MB** "
            f"(−{(1 - cover / flat) * 100:.1f}%), narrowing {len(narrowed)} of {len(default)}. "
            f"End-to-end that is **{speedup:.2f}× on the classes it narrows** — against a "
            f"measured noise floor of {floor:.2f}× on the classes where the candidate set is "
            "byte-identical and no speedup is possible, so the attributable part is roughly "
            f"{speedup / floor:.2f}×."
        ),
    ]
    if twin := next((r for r in rows if r["class"] == ASCII_TWIN), None):
        cut = (1 - int(twin["cover_bytes"]) / int(twin["flat_bytes"])) * 100
        lines += [
            "",
            (
                "**Where it does not win, and why.** `stress-isodate` is flat in production "
                "and the reason is semantic, not a planner defect: under gist's rg-parity "
                "Unicode default `\\d` denotes `\\p{Nd}`, ~680 codepoints, so the ASCII digit "
                "trigrams are **not** necessary conditions and no sound plan exists. "
                "csearch's Go `\\d` is the ten ASCII digits, which is why the head-to-head "
                "row above — measured under ASCII semantics for both tools — shows a win the "
                "default-flag run does not. Spell the same intent as `(?-u)\\d{4}…` or pass "
                f"`--no-unicode` and the cover fires: that is the `{ASCII_TWIN}` row, "
                f"−{cut:.1f}% and {_ratio([twin]):.2f}× on the same corpus."
            ),
        ]
    return lines, failures


def _ratio(rows: list[dict]) -> float:
    """Aggregate flat:cover wall ratio, 1.0 when there is nothing to divide."""
    c = sum(int(r["cover_us"]) for r in rows)
    return sum(int(r["flat_us"]) for r in rows) / c if c else 1.0


def render(
    rows: list[dict],
    meta: dict[str, str],
    cost: dict[str, dict] | None,
    cost_meta: dict[str, str],
    machine: str,
    zig: str,
    prod: list[dict] | None = None,
) -> tuple[str, list[str]]:
    """(markdown section, failures). A non-empty failures list must block the splice."""
    by_class: dict[str, dict[str, dict]] = {}
    order: dict[str, list[str]] = {"shared": [], "stress": []}
    for r in rows:
        by_class.setdefault(r["class"], {})[r["arm"]] = r
        slate = r["slate"]
        if r["class"] not in order[slate]:
            order[slate].append(r["class"])

    failures: list[str] = []
    for cls, arms in by_class.items():
        missing = [a for a in ARMS if a not in arms]
        if missing:
            failures.append(f"{cls}: missing arm(s) {', '.join(missing)}")
            continue
        hits = {a: arms[a]["hits"] for a in ARMS}
        if len(set(hits.values())) != 1:
            failures.append(f"{cls}: arms disagree on verified hits {hits} — a formula is UNSOUND")
        if int(arms["gist"]["cand_bytes"]) > int(arms["csearch"]["cand_bytes"]):
            failures.append(
                f"{cls}: gist admits {arms['gist']['cand_bytes']} B vs csearch "
                f"{arms['csearch']['cand_bytes']} B — a per-class REGRESSION"
            )

    every = order["shared"] + order["stress"]
    tot = totals(by_class, every)
    if tot["gist"] >= tot["csearch"]:
        failures.append(
            f"gist admits {tot['gist']} candidate bytes vs csearch {tot['csearch']} — "
            "not strictly fewer, so there is no win to splice"
        )

    size_note = build_note = "not measured"
    if cost:
        g, c = cost["gist"], cost["csearch"]
        size_ratio = int(g["index_bytes"]) / int(c["index_bytes"])
        build_ratio = float(g["build_ms"]) / float(c["build_ms"])
        if size_ratio > MAX_SIZE_RATIO:
            failures.append(
                f"gist's index is {size_ratio:.2f}× csearch's (> {MAX_SIZE_RATIO}) — "
                "selectivity bought with a pathologically bigger index is not a better index"
            )
        if build_ratio > MAX_BUILD_RATIO:
            failures.append(
                f"gist's build is {build_ratio:.2f}× csearch's (> {MAX_BUILD_RATIO})"
            )
        size_note = f"{size_ratio:.2f}× csearch"
        build_note = f"{1 / build_ratio:.1f}× faster than csearch" if build_ratio < 1 else f"{build_ratio:.2f}× csearch"

    corpus_docs = meta.get("corpus_docs", "?")
    corpus_mib = mib(int(meta.get("corpus_bytes", 0))) if meta.get("corpus_bytes") else "?"
    won = sum(
        1
        for c in every
        if int(by_class[c]["gist"]["cand_bytes"]) < int(by_class[c]["csearch"]["cand_bytes"])
    )
    lost = sum(
        1
        for c in every
        if int(by_class[c]["gist"]["cand_bytes"]) > int(by_class[c]["csearch"]["cand_bytes"])
    )

    lines = [
        START,
        HEADER,
        "",
        (
            "_The claim under test: **\"your trigram index is csearch-class, not better.\"** "
            "csearch (Google Code Search, Russ Cox 2012) is gist's acknowledged trigram "
            "ancestor, and the honest axis for comparing two indexes is **not** wall time — "
            "that confounds the index with the walk, the IO and the matcher — but **filter "
            "quality**: the candidate BYTES a query admits, and the precision of what it "
            "admits. So `zig build indexq` holds everything else fixed — one corpus, one "
            "built index, one evaluator (`Index.queryPlan`), one verifier (the production "
            "matcher) — and varies only the boolean formula over trigrams. csearch's arm is "
            "**csearch's own formula**, lifted verbatim from `csearch -verbose` by "
            "`bench/sieve/csearch_plan.py` and replayed against gist's postings: not a "
            "reimplementation, not a proxy. `gist-base` is gist's pre-Layer-L planner (one "
            "required literal, else the alternation cover), carried so each improvement is "
            "attributable._"
        ),
        "",
        f"- machine: **{machine}** · zig `{zig}` · corpus {corpus_docs} files · {corpus_mib} MiB",
        f"- **{won} classes won, {lost} lost, {len(every) - won - lost} tied** · total candidate bytes "
        f"**{tot['gist'] / 1e9:.3f} GB vs csearch's {tot['csearch'] / 1e9:.3f} GB** "
        f"(gist admits {(1 - tot['gist'] / tot['csearch']) * 100:.1f}% less), from "
        f"{tot['gist-base'] / 1e9:.3f} GB before Layer L",
        f"- index size {size_note} · build {build_note}",
        "",
        "### The certificate's own twelve classes",
        "",
        (
            "_The slate Layers A and D already publish, reported first and unedited: nobody "
            "can call it chosen to flatter gist. Eight of the twelve cannot separate two "
            "planners at all — four are single-literal (every planner emits the same run) and "
            "four are structurally unfilterable (literal-free `\\w{3,8}`, sub-trigram `})` and "
            "`;$`, and `panic|0x` whose two-byte branch makes the disjunction vacuous), where "
            "the only sound answer is \"no filter\" and both tools give it._"
        ),
        "",
    ]
    lines += table(by_class, order["shared"])
    lines += [
        "",
        "### The planner-stress slate",
        "",
        (
            "_Eight shapes a real code search produces, chosen because csearch's planner has "
            "a real, non-obvious answer for each — the AND-of-OR boundary-trigram products "
            "that make csearch a strong planner rather than a caricature. Declared in "
            "`bench/sieve/stress.zig`; csearch's rendered query for every row is in the run "
            "log._"
        ),
        "",
    ]
    lines += table(by_class, order["stress"])

    if cost:
        g, c = cost["gist"], cost["csearch"]
        lines += [
            "",
            "### Index cost (same file list, `bench/sieve/indexcost.sh`)",
            "",
            "| tool | index | per corpus byte | build | peak RSS |",
            "|---|--:|--:|--:|--:|",
        ]
        cb = int(cost_meta.get("corpus_bytes", 0)) or 1
        for name in ("gist", "csearch"):
            r = cost[name]
            lines.append(
                f"| {name} | {int(r['index_bytes']) / 1e6:.1f} MB "
                f"| {int(r['index_bytes']) / cb:.3f} "
                f"| {float(r['build_ms']) / 1000:.2f} s "
                f"| {int(r['peak_rss_bytes']) / 1e6:.1f} MB |"
            )
        lines += [
            "",
            (
                f"Both indexes cover the byte-identical file list ({cost_meta.get('corpus_files', '?')} "
                "files — gist's own persisted `paths.list`, the fairness contract "
                "`bench/races/_compete.sh` already owns). The RSS figures are not like-for-like "
                "and are reported as measured: `cindex` is driven in 400-path batches (its own "
                "documented shape, forced by argv limits), so its peak is one batch, while "
                "gist's is the whole corpus in a single parallel pass."
            ),
        ]

    if prod is not None:
        prod_lines, prod_failures = production(prod)
        lines += prod_lines
        failures += prod_failures

    lines += [
        "",
        (
            "> **What is disproven.** The two planners are not the same planner. csearch stops "
            "at 3-byte boundary trigrams and takes ONE window out of a class-punctuated run; "
            "gist's conjunctive cover (`src/kernel/match/query/cover.zig`) keeps every "
            "mandatory run, reads `x?` as the finite set {ε, x} so a scheme factors into whole "
            "literals, and emits every sound clause so the **cost-ordered evaluator** — which "
            "knows real posting cardinalities — picks and declines. Soundness is the fixed "
            "point, not the variable: `matched ⇒ never pruned` is brute-forced against the "
            "production matcher over an exhaustively enumerated document space "
            "(`cover_test.zig`), and the harness independently fails closed if any arm's "
            "verified hit count differs."
        ),
        "",
        (
            "> **And it is the product, not a harness.** The cover is wired onto the cold "
            "query path: `gate.coverPlan` derives it from the effective pattern under "
            "`arm.linearOptions` — the same flags the matcher compiled with, so the plan "
            "cannot disagree with the engine — and `elide.askIndex` puts it to the index "
            "ahead of the flat OR, which stays the fallback. A run's whole answer is "
            "unchanged: `bench/sieve/cover_parity.sh` holds the wired path byte-identical to "
            "the pre-wiring prefilter, to gist's own `--no-index` read, and to ripgrep across "
            "21 cases on a frozen real-source corpus — including `-i`, `-U`, `-F`, multi-`-e`, "
            "PCRE2 and the unprovable patterns, each of which exercises a different "
            "stand-down. Caseless and PCRE2 deliberately keep their existing prefilters "
            "(a folded-AST cover and a foreign-grammar cover are each a soundness argument "
            "this layer has not made), so they are certified as unchanged, not as improved."
        ),
        END,
    ]
    return "\n".join(lines) + "\n", failures


#: The layer's receipt in `bench/certify/artifact/`, for the roster in layers.py.
SIDECAR = "indexq.csv"


def publish(cert: Path, rows: list[dict], cost: dict[str, dict] | None, prod: list[dict] | None):
    """Write every number the prose cites as one tidy side-car beside the mint.

    Long format — one row per (table, subject, metric) — rather than three wide
    tables glued together: the three inputs are keyed differently (class, tool,
    class) and a union schema would be mostly holes. This way the receipt parses
    with a plain reader and a reviewer can diff any single number against the
    sentence that quotes it.
    """
    out: list[tuple[str, str, str, str]] = []
    for r in rows:
        for k, v in r.items():
            if k not in ("class", "slate"):
                out.append(("headhead", f"{r.get('slate', '')}/{r['class']}".lstrip("/"), k, v))
    for tool, r in (cost or {}).items():
        out += [("cost", tool, k, v) for k, v in r.items() if k != "tool"]
    for r in prod or ():
        out += [("production", r["class"], k, v) for k, v in r.items() if k != "class"]

    path = cert.parent / SIDECAR
    with path.open("w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t", lineterminator="\n")
        w.writerow(("table", "subject", "metric", "value"))
        w.writerows(out)
    return path


def splice(cert: Path, section: str) -> None:
    """Replace the one marked block and retire pre-marker duplicates."""
    text = cert.read_text() if cert.exists() else "# gist — Dominance-and-Fit Certificate\n\n"
    lo = text.find(START)
    if lo != -1:
        hi = text.find(END, lo + len(START))
        if hi == -1:
            raise ValueError("indexq certificate has a start marker without an end marker")
        prefix = text[:lo]
        while (orphan_hi := prefix.rfind(END)) != -1 and (
            orphan_lo := prefix.rfind(HEADER, 0, orphan_hi)
        ) != -1:
            prefix = (
                prefix[:orphan_lo].rstrip()
                + "\n\n"
                + prefix[orphan_hi + len(END) :].lstrip("\n")
            )
        text = prefix + section + text[hi + len(END) :].lstrip("\n")
    else:
        text = text.rstrip() + "\n\n" + section
    if not text.endswith("\n"):
        text += "\n"
    cert.write_text(text)


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(description="gist Layer L (index quality vs csearch) report")
    ap.add_argument("--certificate", type=Path, required=True)
    ap.add_argument("--tsv", type=Path, required=True, help="from `zig build indexq`")
    ap.add_argument("--cost-tsv", type=Path, help="from `bench/sieve/indexcost.sh`")
    ap.add_argument(
        "--production-tsv", type=Path, help="from `bench/sieve/production.sh` (the wired path)"
    )
    ap.add_argument("--machine", default="?")
    ap.add_argument("--zig", default="?")
    args = ap.parse_args()

    rows, meta = read_tsv(args.tsv)
    if not rows:
        print("certify_indexq_report: empty TSV — nothing to splice")
        return 1

    cost = cost_meta = None
    if args.cost_tsv and args.cost_tsv.exists():
        cost_rows, cost_meta = read_tsv(args.cost_tsv)
        cost = {r["tool"]: r for r in cost_rows}

    prod = None
    if args.production_tsv and args.production_tsv.exists():
        prod, _ = read_tsv(args.production_tsv)

    section, failures = render(
        rows, meta, cost, cost_meta or {}, args.machine, args.zig, prod
    )
    if failures:
        print("certify_indexq_report: REFUSING to splice a win — Layer L is fail-closed:")
        for f in failures:
            print(f"  - {f}")
        return 1

    splice(args.certificate, section)
    sidecar = publish(args.certificate, rows, cost, prod)
    print(f"wrote Layer L (index quality vs csearch) → {args.certificate}")
    print(f"published side-car → {sidecar}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
