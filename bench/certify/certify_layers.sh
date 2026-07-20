#!/usr/bin/env bash
# certify_layers.sh — populate Layers B / B′ / C / D into CERTIFICATE.md.
#
# Layer A (micro + macro) must already exist at .local/gist-verify/CERTIFICATE.md
# (minted by `zig build certify` / `bench/certify/certify.sh`). This script is
# the automatic second half: build the lab binaries, measure what this machine
# can measure (PMU under passwordless/forced sudo when available), splice every
# remaining layer, and leave the certificate complete by its own four-layer
# standard — never inventing cycles when the PMU is unavailable.
#
# Usage (from repo root or anywhere):
#   bash pkg/kernels/irregex/bench/certify/certify_layers.sh
#
# Env:
#   CERT_SUDO=auto|1|0   auto (default): use `sudo -n` when it works;
#                        1: allow an interactive sudo prompt;
#                        0: never escalate (wall-clock / cross-check only).
#   CERT_OUT=DIR         certificate dir (default: <repo>/.local/gist-verify)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="$(cd "${HERE}/../.." && pwd)"
REPO="$(cd "${KERNEL}/../../.." && pwd)"
OUT="${CERT_OUT:-${REPO}/.local/gist-verify}"
CERT="${OUT}/CERTIFICATE.md"
CERT_SUDO="${CERT_SUDO:-auto}"

die() {
  echo "certify_layers: $*" >&2
  exit 1
}
note() { echo "certify_layers: $*"; }

[[ -s "${CERT}" ]] || die "missing ${CERT} — run Layer A first (zig build -Doptimize=ReleaseFast certify / bench/certify/certify.sh)"
[[ -s "${OUT}/certify.csv" ]] || die "missing ${OUT}/certify.csv — Layer A micro incomplete"

# ── build ReleaseFast lab binaries (install only — `lab` does not auto-run) ──
note "building lab binaries (ReleaseFast)…"
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast lab) || die "lab build failed"

PORTBOUND="${KERNEL}/zig-out/bin/gist-portbound"
ROOFLINE="${KERNEL}/zig-out/bin/gist-roofline"
LOWERBOUND="${KERNEL}/zig-out/bin/gist-lowerbound"
for bin in "${PORTBOUND}" "${ROOFLINE}" "${LOWERBOUND}"; do
  [[ -x "${bin}" ]] || die "missing executable ${bin}"
done

# ── optional root re-run for PMU (kperf is root-gated on xnu) ─────────────────
# Never re-run gist-bench certify here: that rewrite wipes the macroscopic
# Layer A section. certify.sh mints A-micro under sudo *before* the macro race.
run_root() { # <abs-bin> [args…] — 0 on success, 1 if skipped/unavailable
  local bin="$1"
  shift
  local uid
  uid="$(id -u)"
  if [[ "${uid}" -eq 0 ]]; then
    (cd "${REPO}" && "${bin}" "$@")
    return $?
  fi
  case "${CERT_SUDO}" in
    0)
      note "CERT_SUDO=0 — skipping root re-run of $(basename "${bin}")"
      return 1
      ;;
    1)
      note "CERT_SUDO=1 — prompting for sudo to run $(basename "${bin}")…"
      (cd "${REPO}" && sudo "${bin}" "$@")
      return $?
      ;;
    auto | *)
      if sudo -n true 2> /dev/null; then
        note "passwordless sudo — re-running $(basename "${bin}") under root for PMU…"
        (cd "${REPO}" && sudo -n "${bin}" "$@")
        return $?
      fi
      note "no passwordless sudo — $(basename "${bin}") stays non-root (cycles labeled NOT measured)"
      return 1
      ;;
  esac
}

# Layer B′ — measured port bound (always run; labels measured/not in JSON)
# Invoke run_root outside `if`/`!` so `set -e` still sees its status (SC2310).
run_root "${PORTBOUND}"
root_rc=$?
if [[ "${root_rc}" -ne 0 ]]; then
  (cd "${REPO}" && "${PORTBOUND}") || die "gist-portbound failed"
fi

# Layer B — static llvm-mca + splice B′ from portbound.json
note "Layer B — portcert (static µarch + B′ splice)…"
llvm_bin="$(brew --prefix llvm 2> /dev/null || true)"
[[ -n "${llvm_bin}" && -d "${llvm_bin}/bin" ]] && PATH="${llvm_bin}/bin:${PATH:-}"
bash "${HERE}/../portcert/portcert.sh" || note "portcert skipped/degraded (see above)"

# Layer C — STREAM ceiling (+ optional root for measured clock)
run_root "${ROOFLINE}"
root_rc=$?
if [[ "${root_rc}" -ne 0 ]]; then
  (cd "${REPO}" && "${ROOFLINE}") || die "gist-roofline failed"
fi
python3 "${HERE}/../roofline/roofline_report.py" \
  --out-dir "${OUT}" \
  --certificate "${CERT}" \
  --portcert "${OUT}/portcert.json" \
  --certify "${OUT}/certify.csv" \
  || die "roofline_report.py failed"

# Layer D — algorithmic floor
(cd "${REPO}" && "${LOWERBOUND}") || die "gist-lowerbound failed"
python3 "${HERE}/../lowerbound/lowerbound_report.py" \
  --certificate "${CERT}" \
  --csv "${OUT}/lowerbound.csv" \
  || die "lowerbound_report.py failed"

# Completeness gate (layers only — full artifact check stays with certify.sh)
missing=0
for hdr in \
  "## Layer B — port-optimality" \
  "## Layer C — roofline" \
  "## Layer D — algorithmic lower bound"; do
  if ! grep -qF "${hdr}" "${CERT}"; then
    echo "certify_layers: CERTIFICATE.md missing section: ${hdr}" >&2
    missing=1
  fi
done
[[ "${missing}" -eq 0 ]] || die "certificate still incomplete after splice"

# Optional publish into the committed artifact dir (crate-relative).
if [[ -n "${CERT_PUBLISH_DIR:-}" ]]; then
  pub="${KERNEL}/${CERT_PUBLISH_DIR}"
  mkdir -p "${pub}/raw"
  for f in CERTIFICATE.md certify.csv certify_macro.csv machine.json \
    tool-versions.txt corpus-manifest.tsv command-log.txt index-sizes.json \
    portcert.json portcert.csv portbound.json roofline.json lowerbound.csv; do
    [[ -f "${OUT}/${f}" ]] && cp -f "${OUT}/${f}" "${pub}/"
  done
  if compgen -G "${OUT}/raw/*.json" > /dev/null; then
    cp -f "${OUT}/raw/"*.json "${pub}/raw/"
  fi
  python3 "${HERE}/check_artifacts.py" \
    --artifacts-dir "${pub}" --artifacts --no-require-head \
    || die "published bundle failed check_artifacts"
  note "published → ${pub}"
fi

note "Layers B/B′/C/D spliced into ${CERT}"
grep -n '^## Layer\|^### Layer' "${CERT}" || true
