#!/usr/bin/env bash
# scanner_headtohead.sh — gist with NO INDEX vs ripgrep, on ripgrep's home turf.
#
# The claim this race exists to test: "gist only wins because it has an index;
# as a pure scanner, ripgrep's design, it loses." So the subject here is
# `gist --no-index` — no persisted trigram index, no crest sidecar, no resident
# daemon (`GIST_NO_AUTOSERVE=1`), nothing but a live directory walk, a read, and
# a scan. Exactly ripgrep's model, over exactly ripgrep's corpus scope.
#
# The 12 classes are byte-identical to `certify/certify.sh`'s PROBES (and to
# `bench/harness/certify.zig`'s), so a scanner-lane row maps 1:1 onto the Layer A
# indexed row above it — same pattern, same roots, same ignore scope, same
# `-l` command shape. The only difference between the `noidx` cell and the `idx`
# cell is whether the index is allowed to elide reads.
#
# WHY THIS SCRIPT DOES ITS OWN TIMING INSTEAD OF CALLING HYPERFINE
# ----------------------------------------------------------------
# hyperfine runs all N samples of command A, *then* all N of command B. On a
# quiescent box that is fine. This tree is not quiescent: ~10 coworking agents
# edit and compile on the same machine, and a load excursion that lands inside
# one command's block biases that command alone — the difference between the
# tools gets confounded with the difference between two moments in time. So this
# race samples ROUND-ROBIN: each round runs every cell once, and the starting
# cell rotates per round, so any drift in machine load is spread across cells
# instead of pooled into one. The samples are then handed to the SAME statistic
# the certificate uses (bootstrap-CI median + Mann-Whitney, `certify_stats.py`)
# by writing one hyperfine-shaped JSON per cell — the reporter reuses
# `load_times_ms` unchanged rather than learning a second format.
#
# Fairness, corpus scope, and the shared ignore flags come from `_compete.sh`
# (SOURCED, never executed) — identical to every other race in this folder.
#
# Usage:
#   bash bench/races/scanner_headtohead.sh                 # RUNS=15 WARMUP=2
#   RUNS=25 bash bench/races/scanner_headtohead.sh         # tighten the CIs
#   SCANNER_LANES="list count" bash bench/races/scanner_headtohead.sh
#   SCANNER_OUT=/tmp/scan bash bench/races/scanner_headtohead.sh
#
# Output: ${SCANNER_OUT}/{class}__{noidx,idx,rg}.json  (hyperfine-shaped)
#         ${SCANNER_OUT}/order.tsv                     (class<TAB>kind<TAB>pattern)
#         ${SCANNER_OUT}/meta.json                     (runs/warmup/roots/lanes)
# Consumed by: bench/certify/certify_scanner_report.py (Layer I).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_compete.sh
source "${HERE}/_compete.sh"

RUNS="${RUNS:-15}"
WARMUP="${WARMUP:-2}"
LANES="${SCANNER_LANES:-list}"
OUTDIR="${SCANNER_OUT:-${COMPETE_DIR}/scanner}"

# The scanner cell must not be quietly accelerated by a resident daemon that a
# previous race left running: `--no-index` disables the persisted index, and
# this disables the warm session that would answer from RAM instead.
export GIST_NO_AUTOSERVE=1

# Byte-identical to certify.sh's PROBES — the scanner lane certifies the same
# 12 classes the indexed macroscopic tier does, so the two tables compare.
PROBES=(
  "literal-rare literal pgxpool"
  "literal-dotted literal context.Context"
  "literal-common literal func"
  "literal-punct2 literal })"
  "regex-decl regex func\\s+\\w+\\("
  "regex-dotted regex pgxpool\\.\\w+"
  "regex-anchored regex ^func\\s"
  "regex-classcount regex [0-9a-f]{8}-[0-9a-f]{4}"
  "regex-alternation regex return|continue|break"
  "regex-dense-scan regex \\w{3,8}"
  "regex-eol regex ;\$"
  "regex-litalt regex panic|0x"
)

# `--no-index` is a gist flag, not a different tool, so the scanner cell is the
# gist command `_compete.sh` already builds with the flag spliced in after the
# binary. Keeping the rest of the argv identical is the point: the noidx and idx
# cells differ by exactly one flag, so their delta IS the index's contribution.
noindex_cmd() { echo "${1/${GIST_BIN} /${GIST_BIN} --no-index }"; }

mkdir -p "${OUTDIR}"
# Two copies of this race sharing one output dir is not a slow run, it is a
# CORRUPT one: both append to order.tsv (the reporter then renders a class
# twice) and both overwrite each other's cells, while each doubles the load the
# other is measuring. Learned the hard way — an earlier invocation was still in
# its count lane when the next started. A directory is the portable atomic lock,
# and it is taken before the build so two runs can't fight over the index either.
LOCK="${OUTDIR}/.owner"
if ! mkdir "${LOCK}" 2> /dev/null; then
  echo "another scanner race already owns ${OUTDIR}" >&2
  echo "  wait for it, or point this one elsewhere: SCANNER_OUT=/tmp/scan2 …" >&2
  echo "  (if you are certain none is running: rmdir ${LOCK})" >&2
  exit 1
fi
trap 'rmdir "${LOCK}" 2> /dev/null' EXIT

# `compete_build_gist_index` runs the whole `zig build` install step, which also
# links the sibling `relate`/`irregex` faces. In a tree ~10 agents are editing,
# one of those faces can be mid-edit and refuse to link while the `gist` exe this
# race times compiled perfectly — and refusing to measure then would be waiting
# on a coworker rather than on anything about gist. SCANNER_NO_BUILD=1 stages the
# already-built exe and re-indexes without invoking the shared build. It is loud
# on purpose: the binary's mtime is printed so a stale measurement is visible.
if [[ "${SCANNER_NO_BUILD:-0}" = 1 ]]; then
  echo "SCANNER_NO_BUILD=1 — staging the existing exe (built $(date -r "${KERNEL}/zig-out/bin/gist" '+%H:%M:%S'))"
  compete_install_gist_bin || exit 1
  (cd "${CORPUS}" && "${GIST_BIN}" index) || exit 1
else
  echo "building gist + persisting the index once (the idx cell needs it)…"
  compete_build_gist_index || exit 1
fi
rm -f "${OUTDIR}"/*.json "${OUTDIR}/order.tsv"

cd "${REPO}" || exit 1
: > "${OUTDIR}/order.tsv"

echo
echo "scanner head-to-head — gist --no-index vs ripgrep (interleaved, runs=${RUNS} +${WARMUP} warmup)"
echo "roots: ${ROOTS[*]} · lanes: ${LANES}"
echo

failed=0
for lane in ${LANES}; do
  for row in "${PROBES[@]}"; do
    read -r class kind pat <<< "${row}"
    case "${lane}" in
      list)
        if [[ "${kind}" = literal ]]; then
          gcmd="$(compete_lit_cmd gist "${pat}")"
          rcmd="$(compete_lit_cmd rg "${pat}")"
        else
          gcmd="$(compete_rgx_cmd gist "${pat}")"
          rcmd="$(compete_rgx_cmd rg "${pat}")"
        fi
        id="${class}"
        ;;
      count)
        # `-l` stops at a file's first hit; `-c` scans every candidate whole.
        # The count lane is the harder scanner test, and it is the one where an
        # index cannot short-circuit anything it hasn't already elided.
        #
        # `compete_count_cmd` is `-F` by construction — the shared registry's
        # count lane is a NEEDLE lane, and every other race feeds it literals.
        # Handing it a regex would silently search for the pattern's SOURCE TEXT
        # as a fixed string (`func\s+\w+\(` matches nothing anywhere), so all
        # eight regex classes would collapse into one empty-result literal scan
        # wearing eight different names. The regex count command is therefore
        # derived locally from the regex LIST command by swapping the emit flag,
        # which keeps roots, SCOPE, `--sort none`, and quoting byte-identical to
        # the shared builder without editing a file every other race sources.
        if [[ "${kind}" = literal ]]; then
          gcmd="$(compete_count_cmd gist "${pat}")"
          rcmd="$(compete_count_cmd rg "${pat}")"
        else
          gcmd="$(compete_rgx_cmd gist "${pat}")"
          rcmd="$(compete_rgx_cmd rg "${pat}")"
          gcmd="${gcmd/ -l / -c }"
          rcmd="${rcmd/ -l / -c }"
        fi
        id="${class}-count"
        ;;
      *)
        echo "unknown lane '${lane}' (want: list count)" >&2
        exit 1
        ;;
    esac
    ncmd="$(noindex_cmd "${gcmd}")"
    printf '%s\t%s\t%s\n' "${id}" "${kind}" "${pat}" >> "${OUTDIR}/order.tsv"

    # Fail-closed semantics BEFORE any timing: the scanner cell must produce
    # ripgrep's exact result set, and so must the indexed cell. A timing number
    # for a wrong answer is worse than no number.
    if ! compete_precheck_equivalent "${ncmd}" "${rcmd}" "${id}/gist --no-index"; then
      echo "  SKIPPED ${id}: gist --no-index is not rg-equivalent — fix the engine, not the race" >&2
      failed=1
      continue
    fi
    if ! compete_precheck_equivalent "${gcmd}" "${rcmd}" "${id}/gist"; then
      echo "  SKIPPED ${id}: indexed gist is not rg-equivalent" >&2
      failed=1
      continue
    fi

    python3 - "${OUTDIR}" "${id}" "${RUNS}" "${WARMUP}" \
      "noidx=${ncmd}" "idx=${gcmd}" "rg=${rcmd}" << 'PY' || failed=1
"""Round-robin interleaved sampler → one hyperfine-shaped JSON per cell.

Each round runs every cell exactly once and the round's starting cell rotates,
so a load excursion is spread across cells rather than pooled into whichever
cell happened to own that stretch of wall clock. Output is drained through a
pipe (not /dev/null) so the emit path is paid identically by every cell, which
is what `hyperfine --output=pipe` does in the sibling races.
"""

import json
from pathlib import Path
import subprocess
import sys
import time

outdir, cell_id, runs, warmup = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
cells = [a.split("=", 1) for a in sys.argv[5:]]

def once(cmd: str) -> float:
    """Wall seconds for one fresh process, output fully drained."""
    t0 = time.perf_counter()
    subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    return time.perf_counter() - t0

for _ in range(warmup):
    for _name, cmd in cells:
        once(cmd)

samples: dict[str, list[float]] = {name: [] for name, _ in cells}
for r in range(runs):
    for k in range(len(cells)):
        name, cmd = cells[(r + k) % len(cells)]
        samples[name].append(once(cmd))

report = []
for name, cmd in cells:
    ts = samples[name]
    ordered = sorted(ts)
    median = ordered[len(ordered) // 2]
    doc = {
        "results": [
            {
                "command": cmd,
                "mean": sum(ts) / len(ts),
                "median": median,
                "min": ordered[0],
                "max": ordered[-1],
                "times": ts,
                "exit_codes": [],
            }
        ]
    }
    (outdir / f"{cell_id}__{name}.json").write_text(json.dumps(doc) + "\n")
    report.append(f"{name} {median * 1000:.1f}ms")
print(f"  {cell_id:<24} " + " · ".join(report))
PY
  done
done

cat > "${OUTDIR}/meta.json" << EOF
{ "runs": ${RUNS}, "warmup": ${WARMUP}, "roots": "${ROOTS[*]}", "lanes": "${LANES}" }
EOF

echo
echo "raw cells → ${OUTDIR}"
if [[ "${failed}" -ne 0 ]]; then
  echo "scanner_headtohead: one or more classes failed the rg-equivalence precheck" >&2
  exit 1
fi
echo "next: python3 bench/certify/certify_scanner_report.py ${OUTDIR} --certificate <CERT> …"
