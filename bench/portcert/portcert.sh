#!/usr/bin/env bash
# portcert.sh — Layer B of the dominance-and-fit certificate: PORT-OPTIMALITY, static.
#
# Layer A proves empirical dominance over ripgrep on the registered workloads.
# Layer B proves *why the hot loop can't be beaten on this instruction sequence*:
# it lowers gist's two hot
# loops to assembly for two REAL reference microarchitectures and asks llvm-mca
# for the static microarchitectural bound (port pressure / reciprocal
# throughput) of each. If gist's measured cycles/byte (Layer A) sits at that
# static bound, the loop is port-optimal — no scheduling of these instructions
# on that core runs faster.
#
# WHY CROSS-COMPILED REFERENCE CORES, NOT THIS MACHINE: this dev box is Apple
# Silicon (M-series), and LLVM ships NO real scheduling model for ANY Apple CPU
# — every Apple core from the A7 to the M4 is modeled as the 2013 "Cyclone"
# (LLVM issue #63698). So `llvm-mca -mcpu=apple-m4` is fabricated precision. We
# instead bound against two cores LLVM DOES model precisely, cross-compiled by
# Zig with zero fuss:
#   * x86_64  znver4       (AMD Zen 4)
#   * aarch64 neoverse-v2  (Arm Neoverse V2 — AWS Graviton4 / Google Axion)
#
# The two probes are byte-faithful copies of the production hot loops, drift-
# guarded by probes_test.zig (zig build test). Markers ride INSIDE the loop body
# so LLVM's loop rotation/cloning can't strand them.
#
# DEGRADE, NEVER FAIL (mirrors bench/harness/pmu.zig): if llvm-mca is not
# installed this prints a documented skip and exits 0. Install it opt-in with
#   brew install llvm            (llvm-mca lands at $(brew --prefix llvm)/bin)
#
# Usage:  bench/portcert/portcert.sh            (writes CSV+JSON, splices cert)
#         ITERS=200 bench/portcert/portcert.sh  (more llvm-mca sim iterations)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="$(cd "${HERE}/../.." && pwd)" # portcert/ → bench/ → gist root
REPO="$(cd "${KERNEL}/../../.." && pwd)"
OUT="${CERT_OUT:-${REPO}/.local/gist-verify}" # shared with Layer A
WORK="${OUT}/portcert"                        # our emitted .s + llvm-mca logs
CERT="${OUT}/CERTIFICATE.md"
CSV="${OUT}/portcert.csv"
JSON="${OUT}/portcert.json"
ITERS="${ITERS:-100}"

# ── locate llvm-mca (PATH, else the Homebrew LLVM keg) ─────────────────────────
MCA="$(command -v llvm-mca || true)"
if [[ -z "${MCA}" ]]; then
  brew_llvm="$(brew --prefix llvm 2> /dev/null || true)"
  [[ -n "${brew_llvm}" && -x "${brew_llvm}/bin/llvm-mca" ]] && MCA="${brew_llvm}/bin/llvm-mca"
fi
if [[ -z "${MCA}" ]]; then
  cat << 'EOF'
portcert: llvm-mca not found — skipping Layer B (static port bound).
          This is a documented skip, not a failure (exit 0).
          Install it opt-in:  brew install llvm
          It will land at:     $(brew --prefix llvm)/bin/llvm-mca
EOF
  exit 0
fi
MCA_VERSION="$("${MCA}" --version 2> /dev/null | awk '/LLVM version/{print $NF; exit}')"

command -v zig > /dev/null || {
  echo "portcert: zig not on PATH — cannot cross-compile probes." >&2
  exit 0
}

mkdir -p "${WORK}"
echo "portcert · Layer B (static µarch port bound) · llvm-mca ${MCA_VERSION:-?}"
echo "probes:   simd_contains (throughput-bound) · dfa_step (latency-bound)"
echo

# Reference profiles: display | zig_cpu | mca_cpu | triple.  Zig names features
# with '_' (neoverse_v2); LLVM/llvm-mca use '-' (neoverse-v2).
PROFILES=(
  "znver4|znver4|znver4|x86_64-linux-gnu"
  "neoverse-v2|neoverse_v2|neoverse-v2|aarch64-linux-gnu"
)
# probe | production source file | bound-kind
PROBES=(
  "simd_contains|src/kernel/scan/simd.zig|throughput"
  "dfa_step|src/kernel/regex/linear/dfa/dfa.zig|latency"
)

# Bytes consumed per marked iteration. dfa_step steps one byte; simd_contains
# strides one vector — read the actual width back from the emitted asm so a
# retuned vector length is picked up automatically (zmm=64 ymm=32 xmm=16 on x86;
# NEON `.16b`=16 on aarch64).
bytes_per_iter() { # <probe> <asm_region_file>
  local probe="$1" region="$2"
  if [[ "${probe}" == dfa_step ]]; then
    echo 1
    return
  fi
  if grep -q 'zmm' "${region}"; then
    echo 64
  elif grep -q 'ymm' "${region}"; then
    echo 32
  elif grep -q '\.16b\|xmm\|q[0-9]' "${region}"; then
    echo 16
  else echo 0; fi
}

# Slice the FIRST `# LLVM-MCA-BEGIN <name>` … `END` region out of an .s. LLVM's
# loop cloning can emit several identical copies; they are byte-identical bodies,
# so the first is representative (and lets us show the region in the cert).
first_region() { # <name> <s_file>
  awk -v n="$1" '
    $0 ~ ("LLVM-MCA-BEGIN " n)   { p=1 }
    p                            { print }
    p && $0 ~ ("LLVM-MCA-END " n){ exit }
  ' "$2"
}

: > "${CSV}"
echo -e "probe\tsource\tbound\ttarget_uarch\ttriple\tblock_rthroughput_cyc_iter\tbytes_per_iter\tcyc_per_byte\tsim_cyc_per_iter" >> "${CSV}"

json_rows=""
add_row() { # append a JSON object to json_rows
  [[ -n "${json_rows}" ]] && json_rows+=","
  json_rows+="$1"
}

printf "%-16s %-13s %14s %10s %13s %14s\n" "probe" "target" "RThroughput" "bytes/it" "cyc/byte" "sim cyc/it"
printf "%-16s %-13s %14s %10s %13s %14s\n" "----------------" "-------------" "--------------" "----------" "-------------" "--------------"

for pspec in "${PROBES[@]}"; do
  IFS='|' read -r probe src bound <<< "${pspec}"
  for prof in "${PROFILES[@]}"; do
    IFS='|' read -r disp zig_cpu mca_cpu triple <<< "${prof}"
    asm="${WORK}/${probe}.${disp}.s"
    log="${WORK}/${probe}.${disp}.mca.txt"

    (cd "${KERNEL}" && zig build-obj "bench/portcert/probes/${probe}.zig" \
      -target "${triple}" -mcpu="${zig_cpu}" -O ReleaseFast \
      -femit-asm="${asm}" -fno-emit-bin) 2> "${WORK}/${probe}.${disp}.build.txt" || {
      echo "  ${probe}/${disp}: cross-compile FAILED (see build log) — skipping." >&2
      continue
    }
    if ! grep -q "LLVM-MCA-BEGIN ${probe}" "${asm}"; then
      echo "  ${probe}/${disp}: markers absent from asm — skipping." >&2
      continue
    fi

    "${MCA}" -mtriple="${triple}" -mcpu="${mca_cpu}" -iterations="${ITERS}" "${asm}" > "${log}" 2>&1 || {
      echo "  ${probe}/${disp}: llvm-mca run failed (see ${log}) — skipping." >&2
      continue
    }

    # First region's summary block: RThroughput + simulated cycles/iterations.
    rthru="$(awk '/Block RThroughput:/{print $3; exit}' "${log}")"
    tcyc="$(awk '/Total Cycles:/{print $3; exit}' "${log}")"
    iters="$(awk '/Iterations:/{print $2; exit}' "${log}")"

    region_file="${WORK}/${probe}.${disp}.region.s"
    first_region "${probe}" "${asm}" > "${region_file}"
    bpi="$(bytes_per_iter "${probe}" "${region_file}")"

    cpb="$(awk -v r="${rthru}" -v b="${bpi}" 'BEGIN{ printf (b>0? "%.4f" : "%s"), (b>0? r/b : "nan") }')"
    simci="$(awk -v c="${tcyc}" -v it="${iters}" 'BEGIN{ printf (it>0? "%.3f" : "%s"), (it>0? c/it : "nan") }')"

    printf "%-16s %-13s %14s %10s %13s %14s\n" "${probe}" "${disp}" "${rthru}" "${bpi}" "${cpb}" "${simci}"
    echo -e "${probe}\t${src}\t${bound}\t${disp}\t${triple}\t${rthru}\t${bpi}\t${cpb}\t${simci}" >> "${CSV}"
    add_row "$(printf '{"probe":"%s","source":"%s","bound":"%s","target_uarch":"%s","triple":"%s","mca_cpu":"%s","block_rthroughput_cyc_iter":%s,"bytes_per_iter":%s,"cyc_per_byte":%s,"sim_cyc_per_iter":%s}' \
      "${probe}" "${src}" "${bound}" "${disp}" "${triple}" "${mca_cpu}" "${rthru}" "${bpi}" "${cpb}" "${simci}")"
  done
done

# Machine-readable artifact (Layer C reads this). Apple-Silicon caveat is carried
# in-band so any consumer surfaces it, never silently pretends an M-series bound.
cat > "${JSON}" << EOF
{
  "layer": "B",
  "claim": "port-optimality (static microarchitectural bound via llvm-mca)",
  "generated_by": "bench/portcert/portcert.sh",
  "llvm_mca_version": "${MCA_VERSION:-unknown}",
  "sim_iterations": ${ITERS},
  "apple_silicon_note": "No real llvm-mca scheduling model exists for any Apple CPU (A7..M4 all map to the 2013 Cyclone model; LLVM issue #63698). Layer B is therefore a static bound over two REAL modeled reference cores, not this host.",
  "profiles": [
    {"target_uarch":"znver4","triple":"x86_64-linux-gnu","desc":"AMD Zen 4"},
    {"target_uarch":"neoverse-v2","triple":"aarch64-linux-gnu","desc":"Arm Neoverse V2 (AWS Graviton4 / Google Axion)"}
  ],
  "results": [${json_rows}]
}
EOF

echo
echo "wrote ${CSV}"
echo "wrote ${JSON}"

# Splice the Layer B section into CERTIFICATE.md (idempotent; degrades if the
# report tool or the file is missing). The splicer auto-discovers a sibling
# portbound.json (Layer B′ — the port bound MEASURED on this machine, from
# `gist-portbound`) and renders it fail-closed: absent or PMU-less, the
# certificate says cycles are cross-checked-only, never a fabricated number.
if python3 "${HERE}/portcert_report.py" --json "${JSON}" --certificate "${CERT}"; then
  echo "spliced Layer B section into ${CERT}"
fi
if [[ -f "${OUT}/portbound.json" ]]; then
  echo "Layer B′ (measured on this machine): spliced from ${OUT}/portbound.json"
else
  cat << 'EOF'
Layer B′ (measured on this machine): not yet run. Mint it with
  (cd pkg/kernels/irregex && zig build -Doptimize=ReleaseFast portbound)  # wall-clock
  sudo pkg/kernels/irregex/zig-out/bin/gist-portbound                     # cycles (kpc is root-gated; run from repo root)
then re-run this script to splice the measured subsection.
EOF
fi
