#!/usr/bin/env bash
# certify_crest.sh — Layer E of the Certificate of Optimality: the crest sieve.
#
# The one place gist's index math is new rather than borrowed. The trigram index
# (and every trigram-family peer) prunes 0% on literal-free class repetitions —
# `[0-9a-f]{12}`, `[0-9]{6}` — the Layer A `regex-classcount` hole (cand%=100%).
# The crest sieve closes it with a sound forced-class-run necessary condition
# (`src/kernel/primitives/crest.zig`, proof in `research/crest/PROOF.md`).
#
# `zig build crest` links the REAL engine, builds the production crest sidecar,
# walks the real corpus, and is FAIL-CLOSED: `matched ⇒ ¬pruned` against the
# production matcher over the whole corpus + randomized adversarial sweeps. A
# single false negative exits non-zero and this script aborts WITHOUT splicing —
# so a spliced Layer E is itself the soundness receipt. No PMU/sudo needed
# (wall-clock full-scan vs sieve-survivors, same matcher both sides).
#
# Usage (from repo root or anywhere):
#   bash pkg/kernels/irregex/bench/certify/certify_crest.sh
# Env:
#   CERT_OUT=DIR   certificate dir (default: <repo>/.local/gist-verify)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="$(cd "${HERE}/../.." && pwd)"
REPO="$(cd "${KERNEL}/../../.." && pwd)"
OUT="${CERT_OUT:-${REPO}/.local/gist-verify}"
CERT="${OUT}/CERTIFICATE.md"
CREST_CSV="${OUT}/crest.csv"
CREST_RAW="${REPO}/.local/crest-evidence/crest.csv"

die() {
  echo "certify_crest: $*" >&2
  exit 1
}
note() { echo "certify_crest: $*"; }

[[ -s "${CERT}" ]] || die "missing ${CERT} — run Layer A first (bench/certify/certify.sh)"

# The standalone proof owns its complete raw evidence package under
# .local/crest-evidence; copy the aggregate into the certificate bundle.
note "building + running the crest production proof (fail-closed)…"
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast crest) \
  || die "crest proof failed — a soundness violation aborts the certificate; do NOT weaken the sieve, fix the calculus"
[[ -s "${CREST_RAW}" ]] || die "crest proof did not emit ${CREST_RAW}"
cp -f "${CREST_RAW}" "${CREST_CSV}"

# Measured-on-this-machine provenance (same brand string the other layers use).
if machine="$(sysctl -n machdep.cpu.brand_string 2> /dev/null)"; then :; else machine="$(uname -m)"; fi
zig="$(cd "${KERNEL}" && zig version)"

python3 "${HERE}/certify_crest_report.py" \
  --certificate "${CERT}" \
  --csv "${CREST_CSV}" \
  --machine "${machine}" \
  --zig "${zig}" \
  || die "certify_crest_report.py failed"

grep -qF "## Layer E — crest sieve" "${CERT}" || die "Layer E section missing after splice"
note "Layer E (crest sieve) spliced into ${CERT}"
