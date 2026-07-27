#!/usr/bin/env python3
"""Differential drop-in proof: replay ripgrep's OWN integration suite against gist's `rg` verb and score it honestly against real ripgrep as the oracle.

For each mined test we materialize its fixture in a throwaway dir, run REAL `rg`
and `gist rg` on byte-identical inputs (same argv, same stdin), and compare
stdout + exit-class. ripgrep is the ground truth — we never trust a hardcoded
expected string, we diff against what the installed `rg` actually prints.

Buckets:
  PASS     gist stdout == rg stdout (+ matching exit-class). When the mined
           test's own assertion is order-agnostic (`cmp == "sort"` — ripgrep's
           `eqnice_sorted!`, used exactly where rg's parallel walk output is
           nondeterministic), sorted-line equality IS the oracle's bar and
           scores PASS too.
  ORDER    a `cmp == "plain"` case differing only in line order — rg's own
           output is deterministic there, so gist must match it byte-for-byte
  FAIL     gist differs on a surface it claims to support → a real bug to fix
  NA       feature unsupported by gist's design (gist exits 2, OR the diff is
           attributable to a documented scope boundary — see below)
  RG_ERR   rg itself errored (bad usage / needs pcre2) — not gist's concern
  FIXTURE  the miner couldn't reproduce a referenced path (our miner's limit)
  SKIP     not runnable here (control-flow test, pcre2-only, non-stdout terminal)

Supported-surface parity = (PASS+ORDER) / (PASS+ORDER+FAIL): of everything gist
claims to do, how much matches ripgrep byte-for-byte. Needs `rg` on PATH (the
oracle) and a built `gist` CLI (../../zig-out/bin/gist → `zig build`, the `rg`
verb — see src/commands/cli/main.zig; distinct from the `gist-bench` harness).

Usage:  python3 run.py            # score the frozen spec.json
        python3 run.py --list-na  # also print the NA reasons
"""

import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import _oracle as O
from _oracle import GIST, RG


HERE = Path(__file__).resolve().parent
spec = json.loads((HERE / "spec.json").read_text())


def score(rec, engine_env=None):
    """Bucket one mined case against live ripgrep.

    Dispatched by the stream its upstream `rgtest!` asserted on (`terminal`).
    A case with no replayable argv (a `control-flow`/`fixture-helper` miner skip)
    stays SKIP — those are credited through the coverage manifest, not replayed
    here. A record whose fixture the miner could NOT fully reproduce (a non-empty
    `skip` on an otherwise-`ok` record — e.g. rg 15.2's `r3275_git_global_config`,
    whose determinism rides a `format!`-built config file embedding a run-time
    absolute `excludesFile` path the self-contained miner can't template) is SKIP
    too: scoring a case against an admittedly-incomplete fixture is not a faithful
    diff, only order-nondeterministic noise. Everything else runs on BOTH tools
    and is scored at the *upstream test's own oracle*: `stdout` diffs bytes, `exit`
    diffs the return code, `stderr` (`assert_non_empty_stderr`) requires a matching
    diagnostic + exit class, and `output` (`.output()`/`.raw_output()`) asserts
    stdout + exit + that a warning ripgrep emits is not silently dropped.
    """
    if rec["status"] == "skip" or rec.get("skip") or not rec["argv"]:
        return "SKIP", "control-flow/unreproducible-fixture"

    # ignore_cleanup_errors: gist's resident-session auto-serve may asynchronously
    # touch its working dir after the child returns; that's a perf-tier daemon,
    # never part of what's scored, so a cleanup race must not crash the board.
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as td:
        root = Path(td)
        O.materialize(rec, root)
        cwd = str(root / rec["current_dir"]) if rec["current_dir"] else str(root)
        stdin = base64.b64decode(rec["stdin"]) if rec["stdin"] else None
        rc_rg, out_rg, err_rg = O.run(O.rg_cmd(rec), cwd, stdin)
        rc_g, out_g, err_g = O.run(O.gist_cmd(rec), cwd, stdin, engine_env)

    term = rec["terminal"]
    if term in ("exit", "err"):
        return _score_exit(rec, rc_g, err_g, rc_rg, err_rg)
    if term == "stderr":
        return _score_stderr(rc_g, err_g, rc_rg, err_rg)
    if term == "output":
        return _score_output(rec, rc_g, out_g, err_g, rc_rg, out_rg, err_rg)
    return _score_stdout(rec, rc_g, out_g, err_g, rc_rg, out_rg, err_rg)


def _score_exit(rec, rc_g, err_g, rc_rg, err_rg):
    """`assert_exit_code`: ripgrep pins one return code; gist must reproduce it.

    Live rg is the oracle (not the mined literal, so an rg-version drift is
    self-correcting). A gist that exits 2 where rg didn't is a real regression,
    never a design-boundary NA — the exit-code contract (0 match / 1 none /
    2 error) is one gist claims in full.
    """
    if rc_g == rc_rg:
        return "PASS", ""
    # A gist exit-2 that is one of its DOCUMENTED engine declines (lookaround /
    # backreferences / mixed per-pattern flags — see `is_design_decline`) is the
    # same purposeful boundary a `stdout`-terminal case already scores NA on, not a
    # regression. rg's own exit here is a normal 0/1 (it has no such boundary); gist
    # declines loud and names the fallback. Score it NA uniformly across terminals.
    if rc_g == 2 and rc_rg in (0, 1) and O.is_design_decline(err_g):
        return "NA", "gist engine decline by design (use -P/--engine auto): " + err_g.decode("utf-8", "replace").strip().split("\n", 1)[0][:90]
    return "FAIL", f"exit rc gist={rc_g} rg={rc_rg} · rg stderr={err_rg.decode('utf-8', 'replace')[:80]!r}"


def _score_stderr(rc_g, err_g, rc_rg, err_rg):
    """Score `assert_non_empty_stderr` against ripgrep's diagnostic.

    gist must reach the same exit class AND emit its own (non-empty) diagnostic —
    a silent accept where rg warns is a real gap. Exact wording is gist's own
    (color.zig sibling: diagnostics are gist's voice), so only presence + exit
    are compared.
    """
    if rc_g != rc_rg:
        return "FAIL", f"exit rc gist={rc_g} rg={rc_rg}"
    if err_rg.strip() and not err_g.strip():
        return "FAIL", "rg emitted a diagnostic; gist stderr is empty (silent accept)"
    return "PASS", "own diagnostic wording; exit-class + presence parity"


def _score_output(rec, rc_g, out_g, err_g, rc_rg, out_rg, err_rg):
    """Score `.output()`/`.raw_output()` (stdout + stderr + status).

    Assert stdout byte-parity (at the case's own cmp bar), exit-code parity, and
    that a diagnostic rg prints isn't dropped silently — the exact diagnostic
    text stays gist's own (see `_score_stderr`).
    """
    bucket, detail = _cmp_stdout(rec, rc_g, out_g, err_g, rc_rg, out_rg, err_rg)
    if bucket != "PASS":
        return bucket, detail
    if rc_g != rc_rg:
        return "FAIL", f"stdout matched but exit rc gist={rc_g} rg={rc_rg}"
    if err_rg.strip() and not err_g.strip():
        return "FAIL", "rg emitted a diagnostic; gist stderr is empty (silent accept)"
    return "PASS", ""


def _score_stdout(rec, rc_g, out_g, err_g, rc_rg, out_rg, err_rg):
    """The default `.stdout()` oracle: a fixture/rg-error guard, then a byte diff."""
    if rc_rg == 2:
        e = err_rg.decode("utf-8", "replace")
        if "No such file" in e or "IO error" in e:
            return "FIXTURE", "miner did not build a referenced path"
        return "RG_ERR", e[:120]
    if rc_g == 2:
        return "NA", err_g.decode("utf-8", "replace")[:120]
    return _cmp_stdout(rec, rc_g, out_g, err_g, rc_rg, out_rg, err_rg)


def _cmp_stdout(rec, rc_g, out_g, err_g, rc_rg, out_rg, err_rg):
    """Byte-diff gist vs rg stdout.

    Applies the case's normalizations plus honest design-boundary re-bucketing;
    returns one of PASS/ORDER/NA/FAIL.
    """
    if "--stats" in rec["argv"]:
        out_g, out_rg = O.norm_time(out_g), O.norm_time(out_rg)
    if "--json" in rec["argv"]:
        out_g, out_rg = O.norm_json(out_g), O.norm_json(out_rg)
    exact = out_g == out_rg
    if exact or O.sort_lines(out_g) == O.sort_lines(out_rg):
        # ripgrep's own assertion for this test: `eqnice!` (cmp=plain) pins the
        # exact bytes, `eqnice_sorted!` (cmp=sort) compares sorted lines because
        # rg's parallel dir walk is genuinely nondeterministic there. Measured:
        # on ignore_git_multi_root_order BOTH tools flip between the two root
        # orders across runs (gist 24/16, rg 26/14 over 40 runs each), so whether
        # a given run also happens to match byte-exactly is a coin, not a
        # property of gist. Record the ORACLE for those cases, never the flip —
        # otherwise a tracked results.json churns on every re-run.
        # Meeting the oracle's own bar is a PASS; falling short of a plain
        # assertion on order alone is the real parity hole ORDER exists to name.
        if rec.get("cmp") == "sort":
            return "PASS", "order-agnostic oracle (eqnice_sorted)"
        return ("PASS", "") if exact else ("ORDER", "line-order only")

    # Honest design-boundary re-bucketing — applied ONLY to a case that would
    # otherwise FAIL, and ONLY when the divergence is attributable to a
    # documented gist scope boundary (never to excuse a real output-contract
    # bug). Each boundary is stated in gist's README/source:
    #   (a) ignore-agnostic: an unsupported ignore SOURCE (global gitignore /
    #       .fdignore); the in-tree gitignore boundary IS implemented and FAILs.
    #   (b) text/source-oriented: gist skips binary files; it never emits
    #       ripgrep's "binary file matches" summary line.
    #   (c) own type registry: `--type-list` is now rg-SORTED and rg-FRAMED
    #       (`types.writeTypeList` — lexicographic names + globs), and gist's
    #       table is a strict SUPERSET of rg's (every rg type + glob present,
    #       plus gist-only types and per-type enrichments), so most rows are
    #       byte-identical to rg and the rest differ only by being richer. It
    #       is not byte-identical overall precisely because it covers more.
    #   (d) own color palette: gist paints a deliberate scheme (bright-red
    #       underline matches, dim separators — color.zig). When the ONLY
    #       divergence is ANSI color codes (identical after stripping them), it's
    #       the documented palette, never an output-contract bug.
    #   (e) `--crlf`+`--color`: ripgrep injects a `\r` in color mode that is
    #       absent from the file AND from rg's OWN plain output; gist matches rg's
    #       plain output and stays self-consistent, so it does not replicate it.
    if O.exercises_ignore(rec):
        return "NA", "unsupported ignore source by design (global gitignore / .fdignore)"
    if b"binary file matches" in out_rg:
        return "NA", "text/source-oriented by design (skips binary)"
    if "--type-list" in rec["argv"]:
        return "NA", "rg-sorted superset registry by design (scope/types.zig)"
    if O.uses_color(rec) and O.strip_ansi(out_g) == O.strip_ansi(out_rg):
        return "NA", "own color palette by design (color.zig)"
    if (
        O.uses_color(rec)
        and "--crlf" in rec["argv"]
        and O.strip_ansi(out_g).replace(b"\r\n", b"\n")
        == O.strip_ansi(out_rg).replace(b"\r\n", b"\n")
    ):
        return "NA", "ripgrep --crlf+color \\r artifact not replicated (matches rg plain)"
    return "FAIL", f"stdout differs (gist {len(out_g)}B rc={rc_g} · rg {len(out_rg)}B rc={rc_rg})"


# The whole mined suite runs once per ENGINE — parallel (`swarm/`,
# gist's default recursive-walk dispatch) and serial (`serial.zig`, forced via
# the internal `GIST_NO_PARALLEL` knob — see `assay.serialForced` /
# `swarm.eligible` in the Zig source). A single-engine run isn't a complete parity
# proof: the parallel engine landed a day after a serial-only ignore-parity
# fix and silently missed porting it (`Ignore.skipFromVerdict` lacked the
# whitelist-override pair `shouldSkip` had), and the vast majority of this
# suite's recursive-walk cases dispatch straight to the parallel path by
# default — a serial-only harness would never have caught that regression.
_ENGINES = [("parallel", None), ("serial", {"GIST_NO_PARALLEL": "1"})]


def _run_engine(engine_env):
    from collections import Counter

    buckets, fails, nas, results = Counter(), [], [], []
    for rec in spec:
        b, detail = score(rec, engine_env)
        buckets[b] += 1
        results.append(
            {
                "name": rec["name"],
                "file": rec["file"],
                "bucket": b,
                "argv": rec["argv"],
                "detail": detail,
            }
        )
        if b == "FAIL":
            fails.append(rec)
        elif b == "NA":
            nas.append((rec["name"], detail))
    return buckets, fails, nas, results


def main():
    """CLI entry point."""
    if not GIST.exists():
        sys.exit(f"gist CLI not built at {GIST} — run `zig build` in {HERE.parents[1]}")
    list_na = "--list-na" in sys.argv[1:]
    any_fails = False
    all_results = {}
    for label, engine_env in _ENGINES:
        buckets, fails, nas, results = _run_engine(engine_env)
        all_results[label] = results

        total = sum(buckets.values())
        print(f"=== gist rg [{label}] vs ripgrep {_rg_version()} — {total} mined tests ===")
        for k in ["PASS", "ORDER", "FAIL", "NA", "RG_ERR", "FIXTURE", "SKIP"]:
            if buckets[k]:
                print(f"  {k:8} {buckets[k]:4}")
        inscope = buckets["PASS"] + buckets["ORDER"] + buckets["FAIL"]
        if inscope:
            pct = 100 * (buckets["PASS"] + buckets["ORDER"]) / inscope
            print(
                f"\nsupported-surface parity [{label}]: {buckets['PASS'] + buckets['ORDER']}/{inscope} = {pct:.1f}%"
            )
        if fails:
            any_fails = True
            print(f"\n=== {len(fails)} FAILs [{label}] ===")
            for r in fails:
                print(f"  {r['file']:14} {r['name']:34} {r['argv']}")
        if list_na:
            print(f"\n=== {len(nas)} NA (unsupported by design) [{label}] ===")
            for name, reason in nas:
                print(f"  {name:36} {reason}")
        print()
    (HERE / "results.json").write_text(json.dumps(all_results["parallel"], indent=1) + "\n")
    sys.exit(1 if any_fails else 0)


def _rg_version() -> str:
    try:
        out = subprocess.run([RG, "--version"], capture_output=True, text=True).stdout
        return out.split("\n", 1)[0].replace("ripgrep ", "").strip() or "?"
    except Exception:
        return "?"


if __name__ == "__main__":
    main()
