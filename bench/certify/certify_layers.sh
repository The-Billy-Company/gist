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
CREST_RAW="${REPO}/.local/crest-evidence/crest.csv"

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
CREST="${KERNEL}/zig-out/bin/crest"
CODEX_SCALE="${KERNEL}/zig-out/bin/codex-scale"
for bin in "${PORTBOUND}" "${ROOFLINE}" "${LOWERBOUND}" "${CREST}" "${CODEX_SCALE}"; do
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
# Capture an expected no-sudo skip without letting `set -e` abort the fallback.
set +e
run_root "${PORTBOUND}"
root_rc=$?
set -e
if [[ "${root_rc}" -ne 0 ]]; then
  (cd "${REPO}" && "${PORTBOUND}") || die "gist-portbound failed"
fi

# Layer B — static llvm-mca + splice B′ from portbound.json
note "Layer B — portcert (static µarch + B′ splice)…"
llvm_bin="$(brew --prefix llvm 2> /dev/null || true)"
[[ -n "${llvm_bin}" && -d "${llvm_bin}/bin" ]] && PATH="${llvm_bin}/bin:${PATH:-}"
bash "${HERE}/../portcert/portcert.sh" || note "portcert skipped/degraded (see above)"

# Layer C — STREAM ceiling (+ optional root for measured clock)
set +e
run_root "${ROOFLINE}"
root_rc=$?
set -e
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

# Layer E — crest sieve (index completeness; the trigram blind spot). No PMU:
# wall-clock full-scan vs sieve-survivors, same matcher. FAIL-CLOSED — a soundness
# violation exits non-zero and aborts the mint; never weaken the sieve to go green.
note "Layer E — crest sieve production proof (fail-closed)…"
(cd "${REPO}" && "${CREST}") \
  || die "crest proof failed (soundness violation) — fix the calculus in src/kernel/math/crest.zig, never weaken the sieve"
[[ -s "${CREST_RAW}" ]] || die "crest proof did not emit ${CREST_RAW}"
cp -f "${CREST_RAW}" "${OUT}/crest.csv"
if crest_machine="$(sysctl -n machdep.cpu.brand_string 2> /dev/null)"; then :; else crest_machine="$(uname -m)"; fi
zig_version="$(cd "${KERNEL}" && zig version)" || die "zig version unavailable"
python3 "${HERE}/certify_crest_report.py" \
  --certificate "${CERT}" \
  --csv "${OUT}/crest.csv" \
  --machine "${crest_machine}" \
  --zig "${zig_version}" \
  || die "certify_crest_report.py failed"

# Layer F — codex self-index (compressed, searchable, decodable). The codex-scale
# harness is fail-closed by construction (die on restore/oracle/cento drift); the
# report re-asserts F1-F5 over its JSONL and refuses to splice on any violation.
note "Layer F — codex self-index proof (fail-closed)…"
CODEX_WORK="${OUT}/codex"
rm -rf "${CODEX_WORK}"
CODEX_OUT="${CODEX_WORK}" CODEX_BIN="${CODEX_SCALE}" \
  bash "${HERE}/../codex/race.sh" "${CODEX_SIZES:-1,4,16}" \
  || die "codex-scale harness failed (correctness violation) — fix src/corpus/index/codex, never weaken the oracle"
python3 "${HERE}/certify_codex_report.py" \
  --certificate "${CERT}" \
  --scale "${CODEX_WORK}/scale.jsonl" \
  --compressors "${CODEX_WORK}/compressors.jsonl" \
  --csv "${OUT}/codex.csv" \
  --machine "${crest_machine}" \
  --zig "${zig_version}" \
  || die "certify_codex_report.py failed (Layer F invariant violated)"

# Completeness gate (layers only — full artifact check stays with certify.sh).
# The header list comes from the shared roster (`layers.py`) that the ledger and
# the reproducibility gate read, so a new layer cannot be spliced here and stay
# invisible to them. The --rank and relate headers are minted by certify.sh, not
# this script, so they are excluded from a layers-only run.
layer_headers="$(python3 "${HERE}/layers.py" headers)" || die "layers.py headers failed"
missing=0
while IFS= read -r hdr; do
  [[ -n "${hdr}" ]] || continue
  case "${hdr}" in
    "## Layer A"* | "## Layer G"*) continue ;;
    *) ;;
  esac
  if ! grep -qF "${hdr}" "${CERT}"; then
    echo "certify_layers: CERTIFICATE.md missing section: ${hdr}" >&2
    missing=1
  fi
done <<< "${layer_headers}"
[[ "${missing}" -eq 0 ]] || die "certificate still incomplete after splice"

# Optional publish into the committed artifact dir (crate-relative).
if [[ -n "${CERT_PUBLISH_DIR:-}" ]]; then
  pub="${KERNEL}/${CERT_PUBLISH_DIR}"
  mkdir -p "${pub}/raw"
  # Bundle-wide files first, then every layer side-car the shared roster names —
  # so a new layer publishes its receipt without a second list to remember.
  layer_sidecars="$(python3 "${HERE}/layers.py" sidecars)" || die "layers.py sidecars failed"
  mapfile -t sidecars <<< "${layer_sidecars}"
  for f in CERTIFICATE.md certify.csv certify_macro.csv machine.json \
    tool-versions.txt corpus-manifest.tsv command-log.txt index-sizes.json \
    portcert.csv portbound.json "${sidecars[@]}"; do
    [[ -f "${OUT}/${f}" ]] && cp -f "${OUT}/${f}" "${pub}/"
  done
  if compgen -G "${OUT}/raw/*.json" > /dev/null; then
    cp -f "${OUT}/raw/"*.json "${pub}/raw/"
  fi
  # A layers-only publish (B–F) is a PARTIAL bundle: the --rank and relate lanes
  # (Layer A rank / Layer G) are minted by certify.sh, not here, so the full
  # reproducibility gate would rightly fail. The canonical committed bundle comes
  # from `certify.sh`, which re-runs check_artifacts over the complete A–G set.
  note "published (partial B–F layers) → ${pub} — full A–G gate runs under certify.sh"
  # A layers-only re-splice still rewrites the tracked certificate, so it is a
  # mint like any other and gets a ledger row — that is how a lane discovers a
  # layer went missing before the docs pinned to it start failing.
  python3 "${HERE}/ledger.py" record --bundle "${pub}" --note "layers-only B–F re-splice" || die "ledger record failed"
fi

note "Layers B/B′/C/D/E/F spliced into ${CERT}"
grep -n '^## Layer\|^### Layer' "${CERT}" || true
