#!/usr/bin/env bash
# mint.sh — gist's Dominance-and-Fit Certificate: Layers A, H, and I.
#
# THIS PACKAGE CERTIFIES WHAT IT BUILDS. gist ships the `gist` binary, so it
# certifies claims that need one running: Layer A's four lanes (microscopic
# cycles/byte, the macroscopic cold race vs the field, the warm resident tier,
# and the `--rank` lane), Layer H's portability matrix, and Layer I's scanner
# mode with the index taken away. The engine's own bounds (B/B′/C/D/E/J/L) are
# minted by `irregex`, and retrieval + multi-pattern (F/G/K) by `relate`, each
# over its own corpus with its own ledger — this mint neither drives nor waits
# on them, which is why there is no `splice.sh` here any more.
#
# The roster this script must satisfy is `guard/profile.py`; the completeness
# gate at the end reads it rather than a second list kept in step by hand.
#
# The 12 classes are byte-identical to certify.zig's probes, so the macroscopic
# table and the microscopic table in CERTIFICATE.md map 1:1 by class name.
#
# Field + fairness scoping come from `dominance/races/field.sh` (same roots, same
# ignore set, each tool on its fastest honest path). gist + indexed rivals
# cold-load an index built ONCE over the same corpus; rg/ugrep/ag/grep re-walk.
#
# Usage:  bash bench/certificate/mint/mint.sh          (RUNS=20 WARMUP=3 by default)
#         RUNS=40 bash bench/certificate/mint/mint.sh  (tighten the CIs)
#         CERT_SUDO=1 CERT_PUBLISH_DIR=bench/certificate/artifact \
#           bash bench/certificate/mint/mint.sh        (mint + publish the receipts)
#
# Env:  CERT_CORPUS_ID   which declared corpus this is measured over; must name a
#                        row in `bench/certificate/corpus.toml`, whose `fetch`
#                        recipe the floor runs if that tree isn't already here
#                        (default: gist-self-v1)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Exported BEFORE the floor is sourced: it is what the floor reads to decide
# which tree to measure, and — more to the point — to refuse the run if the tree
# it would walk is not the one this bundle will claim.
export CERT_CORPUS_ID="${CERT_CORPUS_ID:-gist-self-v1}"
# shellcheck source=../../dominance/races/field.sh
source "${HERE}/../../dominance/races/field.sh"
need_hyperfine

# Refuse to mint a certificate whose machine.git_commit could not equal a clean
# HEAD — unless CERT_ALLOW_DIRTY=1 (local refresh / coworking trees).
if ! git -C "${KERNEL}" rev-parse --verify HEAD > /dev/null 2>&1; then
  echo "certificate aborted: cannot resolve git HEAD" >&2
  exit 1
fi
dirty="$(git -C "${KERNEL}" status --porcelain 2> /dev/null || true)"
if [[ -n "${dirty}" && "${CERT_ALLOW_DIRTY:-0}" != "1" ]]; then
  echo "certificate aborted: worktree is dirty — commit or isolate changes before certifying" >&2
  echo "(local refresh: CERT_ALLOW_DIRTY=1 bash bench/certificate/mint/mint.sh — B–E only)" >&2
  git -C "${KERNEL}" status --porcelain >&2
  exit 1
fi

RUNS="${RUNS:-20}"
WARMUP="${WARMUP:-3}"
WORK="${COMPETE_DIR}/certify"
CERT="${OUT}/CERTIFICATE.md"
MACRO_CSV="${OUT}/certify_macro.csv"
rm -rf "${WORK}"
mkdir -p "${WORK}" "${OUT}"

echo "measuring microscopic Layer A (ReleaseFast)…"
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast certify) || {
  echo "certificate aborted: microscopic certify run failed" >&2
  exit 1
}
[[ -s "${OUT}/certify.csv" ]] || {
  echo "certificate aborted: microscopic run did not emit ${OUT}/certify.csv" >&2
  exit 1
}
# PMU re-run BEFORE the macroscopic race — `gist-bench certify` rewrites the
# whole CERTIFICATE.md, so it must happen before any later lane splices. Uses
# passwordless sudo when available (CERT_SUDO=1 to prompt; CERT_SUDO=0 to skip).
BENCH_BIN="${KERNEL}/zig-out/bin/gist-bench"
if [[ -x "${BENCH_BIN}" ]] && ! grep -q 'cycles/byte provenance: \*\*measured on this machine\*\*' "${CERT}" 2> /dev/null; then
  case "${CERT_SUDO:-auto}" in
    0) echo "  CERT_SUDO=0 — Layer A micro stays wall-clock (no PMU)" ;;
    1)
      echo "  CERT_SUDO=1 — re-running microscopic Layer A under sudo for cycles…"
      (cd "${KERNEL}" && sudo "${BENCH_BIN}" certify) || {
        echo "certificate aborted: sudo microscopic certify failed" >&2
        exit 1
      }
      ;;
    *)
      if sudo -n true 2> /dev/null; then
        echo "  passwordless sudo — re-running microscopic Layer A under root for cycles…"
        (cd "${KERNEL}" && sudo -n "${BENCH_BIN}" certify) || {
          echo "certificate aborted: sudo -n microscopic certify failed" >&2
          exit 1
        }
      else
        echo "  no passwordless sudo — Layer A micro stays wall-clock (cycles labeled NOT measured)"
        echo "  tip: CERT_SUDO=1 bash bench/certificate/mint/mint.sh   # prompt once for PMU"
      fi
      ;;
  esac
fi

# class  kind  pattern — byte-identical to certify.zig's `probes` (patterns have
# no spaces, so `read class kind pat` recovers the pattern as the trailing field).
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

echo "building gist + persisting the index once…"
compete_build_gist_index || exit 1
echo "building competitor indexes…"
compete_build_csearch
compete_build_zoekt

tools_raw="$(compete_tools regex)"
mapfile -t tools <<< "${tools_raw}"
echo
echo "macroscopic race — fresh-process cold query, hyperfine runs=${RUNS} (+${WARMUP} warmup)"
echo "field: gist ${tools[*]}"
echo

# One hyperfine JSON per (class, tool). A gist cell additionally takes its
# official-rg oracle and must prove an exact, order-insensitive file set first.
bench_one() { # <class> <tool> <cmd> [rg-oracle] → 0 timed, 1 rejected
  local class="$1" tool="$2" cmd="$3" oracle="${4:-}" attempt log
  [[ -z "${cmd}" || "${cmd}" = "false" ]] && return 0
  if [[ -n "${oracle}" ]]; then
    compete_precheck_equivalent "${cmd}" "${oracle}" "${class}/${tool}" || return 1
  else
    compete_precheck_status "${cmd}" "${class}/${tool}" || return 1
  fi
  log="${WORK}/${class}__${tool}.hyperfine.log"
  for attempt in 1 2; do
    rm -f "${WORK}/${class}__${tool}.json"
    if compete_hyperfine --warmup "${WARMUP}" --runs "${RUNS}" \
      --export-json "${WORK}/${class}__${tool}.json" \
      "${cmd}" > /dev/null 2> "${log}"; then
      rm -f "${log}"
      return 0
    fi
    [[ "${attempt}" = 1 ]] && echo "  transient timing failure ${class}/${tool}; retrying clean cell…" >&2
  done
  echo "  CELL FAILED during timing ${class}/${tool}: ${cmd}" >&2
  awk 'NR <= 20 { print "    " $0 }' "${log}" >&2
  return 1
}

cd "${CORPUS}" || exit 1
: > "${WORK}/order.tsv"
for row in "${PROBES[@]}"; do
  read -r class kind pat <<< "${row}"
  printf '%s\t%s\t%s\n' "${class}" "${kind}" "${pat}" >> "${WORK}/order.tsv"
  if [[ "${kind}" = literal ]]; then
    gcmd="$(compete_lit_cmd gist "${pat}")"
    rcmd="$(compete_lit_cmd rg "${pat}")"
  else
    gcmd="$(compete_rgx_cmd gist "${pat}")"
    rcmd="$(compete_rgx_cmd rg "${pat}")"
  fi
  # gist is the subject of the certificate: a hard failure invalidates it, so abort.
  bench_one "${class}" gist "${gcmd}" "${rcmd}" || {
    echo "certificate aborted: gist failed equivalence/status on ${class}" >&2
    exit 1
  }
  printf "  %-18s " "${class}"
  for t in "${tools[@]}"; do
    if [[ "${kind}" = literal ]]; then
      cmd="$(compete_lit_cmd "${t}" "${pat}")"
    else cmd="$(compete_rgx_cmd "${t}" "${pat}")"; fi
    # A competitor hard failure warns + excludes that cell (no set -e here), but
    # does not abort gist's certificate.
    bench_one "${class}" "${t}" "${cmd}"
  done
  echo "done"
done

# meta for the report
roots_str="${ROOTS[*]}"
cat > "${WORK}/meta.json" << EOF
{ "runs": ${RUNS}, "warmup": ${WARMUP}, "roots": "${roots_str}" }
EOF

echo
echo "computing bootstrap-CI medians + Mann-Whitney dominance (gist vs rg)…"
python3 "${HERE}/../report/stats.py" "${WORK}" \
  --certificate "${CERT}" \
  --csv "${MACRO_CSV}" \
  --order "${WORK}/order.tsv" \
  --meta "${WORK}/meta.json"

echo "macroscopic section appended to ${CERT}"

# ── reproducibility artifacts — a certificate a third party can regenerate from
# committed bytes: raw samples + the machine/tool/corpus provenance that produced
# them (check_artifacts.py enforces this set). ──
echo "emitting reproducibility metadata…"
rm -rf "${OUT}/raw"
mkdir -p "${OUT}/raw"
raw_files=("${WORK}"/*__*.json)
[[ -f "${raw_files[0]}" ]] || {
  echo "certificate aborted: no raw hyperfine cells were emitted" >&2
  exit 1
}
cp -f "${raw_files[@]}" "${OUT}/raw/"

# Machine, tool, and corpus provenance — the three artifacts that make a number
# re-derivable by a stranger. The emitter is vendored apparatus, so all four
# packages write the identical bundle shape the vendored gate then judges; a
# rival's exact identity (version AND executable digest, resolved past any
# version-manager shim) is its problem to solve, not this script's.
pins=(--tool "gist=${GIST_BIN}")
for t in zig hyperfine "${tools[@]}"; do
  executable="${t}"
  [[ "${t}" = gitgrep ]] && executable=git
  tool_bin="$(command -v "${executable}")" || exit 1
  pins+=(--tool "${t}=${tool_bin}")
done
[[ "${CERT_ALLOW_DIRTY:-0}" = "1" ]] && pins+=(--allow-dirty)

# --root is the CORPUS (paths.list is relative to it), --source-root the
# checkout whose HEAD built the binaries. They differ whenever the race runs
# against an immutable corpus snapshot, and hashing the manifest against the
# wrong one silently produces rows for files that were never searched.
python3 "${HERE}/../../apparatus/provenance.py" \
  --out "${OUT}" --root "${CORPUS}" --source-root "${KERNEL}" \
  --corpus-id "${CERT_CORPUS_ID}" \
  --roots "${roots_str}" --paths-list "${PATHS_LIST}" \
  --runs "${RUNS}" --warmup "${WARMUP}" \
  "${pins[@]}" || exit 1

python3 - "${OUT}/raw" "${OUT}/command-log.txt" << 'PY' || exit 1
import json
import sys
from pathlib import Path

raw_dir, out = map(Path, sys.argv[1:3])
lines = []
for jf in sorted(raw_dir.glob("*__*.json")):
    doc = json.loads(jf.read_text())
    results = doc.get("results") or []
    if len(results) != 1 or not results[0].get("command"):
        raise SystemExit(f"raw cell lacks one exact command: {jf}")
    command = results[0]["command"]
    if "\n" in command or "\t" in command:
        raise SystemExit(f"command log cannot encode control characters: {jf}")
    lines.append(f"{jf.name}\t{command}")
out.write_text("\n".join(lines) + "\n")
print(f"  command-log.txt: {len(lines)} timed commands")
PY

python3 "${HERE}/../../conformance/gates/oracle/index_size_accounting.py" \
  --index-dir "${OUT}" --csearch "${CSEARCH_IDX}" --zoekt "${ZOEKT_DIR}" || exit 1

# Warm tier — the resident-daemon regime an agent actually drives.
# Additive: splices a marked section into CERTIFICATE.md + emits
# certify_warm.csv. Never blocks the mint (a missing daemon/rival is honestly
# reported), so the cold Layer A lanes stay the reproducibility-gated headline.
echo "racing the warm tier (resident daemon)…"
RUNS="${RUNS}" WARMUP="${WARMUP}" bash "${HERE}/warm.sh" \
  || echo "  warm tier skipped (daemon/rival unavailable) — cold cert unaffected" >&2

# --rank lane — the one output shape rg can't express (Layer A). Fail-closed: the
# report enforces no-fabrication + coverage + def-boost + codegen-demote + bounded
# overhead + beats-rg, and any violation aborts the mint. Needs only rg + the
# index this run already persisted, both guaranteed on a certification machine.
echo "certifying the --rank lane (fail-closed)…"
RUNS="${RUNS}" WARMUP="${WARMUP}" bash "${HERE}/rank.sh" || exit 1

# Layer H — the portability matrix, graded by what this machine actually
# executed rather than by what the target list hoped for.
echo "certifying portability (Layer H)…"
python3 "${HERE}/../../conformance/targets/portable.py" run \
  --out "${WORK}/portable.json" || exit 1
python3 "${HERE}/../report/portable.py" \
  --certificate "${CERT}" \
  --json "${WORK}/portable.json" \
  --receipt "${OUT}/portable.json" || exit 1

# Layer I — scanner mode: gist with its index taken away, on ripgrep's home
# turf, cross-checked against the rg conformance suite so a speed number can
# never come from answering a different question.
echo "certifying scanner mode + rg conformance (Layer I)…"
RUNS="${RUNS}" WARMUP="${WARMUP}" bash "${HERE}/../../dominance/races/scanner.sh" || exit 1
python3 "${HERE}/../../conformance/rgsuite/surface.py" --json "${WORK}/rgsurface.json" || exit 1
python3 "${HERE}/../../conformance/rgsuite/fuzz.py" --json "${WORK}/rgfuzz.json" || exit 1
python3 "${HERE}/../report/scanner.py" "${COMPETE_DIR}/scanner" \
  --certificate "${CERT}" \
  --csv "${OUT}/scanner.csv" \
  --fuzz "${WORK}/rgfuzz.json" \
  --conformance "${WORK}/rgsurface.json" || exit 1

# Structural completeness only — a bundle is judged on its bytes, never on the
# tree that produced it. Clean-START is the top gate's job; the recorded
# git_commit is provenance a human can follow, not a condition.
python3 "${HERE}/../guard/artifacts.py" --artifacts-dir "${OUT}" --artifacts || exit 1

# Publish a committed snapshot when asked (CERT_PUBLISH_DIR is crate-relative).
if [[ -n "${CERT_PUBLISH_DIR:-}" ]]; then
  pub="${KERNEL}/${CERT_PUBLISH_DIR}"
  rm -rf "${pub}/raw"
  mkdir -p "${pub}/raw"
  cp -f "${CERT}" "${OUT}/certify.csv" "${MACRO_CSV}" "${OUT}/machine.json" \
    "${OUT}/tool-versions.txt" "${OUT}/corpus-manifest.tsv" \
    "${OUT}/command-log.txt" "${OUT}/index-sizes.json" "${pub}/"
  # Every layer side-car this package's charter names, plus the warm CSV.
  # Driving the list from `profile.py` means a new layer publishes its receipt
  # without a second list to keep in step.
  layer_sidecars="$(python3 "${HERE}/../guard/profile.py" sidecars)" || exit 1
  mapfile -t sidecars <<< "${layer_sidecars}"
  for side in certify_warm.csv "${sidecars[@]}"; do
    [[ -f "${OUT}/${side}" ]] && cp -f "${OUT}/${side}" "${pub}/"
  done
  cp -f "${OUT}/raw/"*.json "${pub}/raw/" || exit 1
  echo "formatting published certificate…"
  (cd "${KERNEL}" && NODE_NO_WARNINGS=1 PRETTIER_EXPERIMENTAL_CLI=1 \
    pnpm -w exec prettier --write "${pub}/CERTIFICATE.md") || exit 1
  # --public-safe is the difference between a mint and a PUBLISH: entering git
  # means a stranger must be able to fetch this corpus and re-derive the number,
  # and it means no private path rides along in a manifest row or an invocation.
  # A bundle that cannot clear it is why the receipts left the tree last time.
  python3 "${HERE}/../guard/artifacts.py" --artifacts-dir "${pub}" --artifacts --public-safe \
    || exit 1
  echo "published reproducible certificate → ${pub}"
  # Log the mint. The certificate is a whole-file rewrite, so without this the
  # tree keeps no memory of what the previous one claimed or which layers it
  # carried — see bench/certificate/ledger/.
  python3 "${HERE}/../ledger/ledger.py" record --bundle "${pub}" || exit 1
fi
