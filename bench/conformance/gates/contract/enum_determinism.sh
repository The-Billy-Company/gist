#!/usr/bin/env bash
# gist enumeration determinism-under-cap oracle.
#
# `equality.sh` proves gist ≡ rg on the FULL (uncapped) matching-file set. This
# gate proves the sibling invariant it can't see — the one the enumeration
# exemption (`corpus.exemptSoftCap`, `Opts.enumeration`) exists to guarantee:
# with the DEFAULT ~25k-token soft context cap ON, the compact per-file modes
#   -l / --files-with-matches · -c / --count · --count-matches ·
#   --files-without-match · --files
# return the COMPLETE, run-to-run-stable set — never a soft-cap-truncated,
# work-stealing-order-dependent SUBSET (the bug that had `gist -l foo` yield a
# different file set each invocation, breaking caching and agent reproducibility).
#
# Two falsifiable assertions per mode, both over the DEFAULT cap (no env budget —
# an explicit GIST_MAX_OUTPUT_TOKENS would suppress the exemption by contract):
#   1. COMPLETE   — default-cap set == GIST_UNCAP=1 set (the cap drops no file).
#   2. STABLE     — three back-to-back default-cap runs are byte-identical as a
#                   sorted set (no nondeterministic subset under truncation).
#
# The test is non-vacuous by construction: a positive control first proves the
# cap is genuinely LIVE on this corpus — a NON-exempt content mode (default line
# search) truncates (capped ⊊ uncapped) — so "enumeration stayed complete" is a
# real exemption, not a corpus too small to ever trip the guard.
#
# Runs the cold work-stealing engine (`GIST_NO_AUTOSERVE=1` + `--no-index`): that
# parallel walk+read+scan fan-out is where the order-dependent truncation lived,
# and skipping the index keeps the gate hermetic + free of coworker index churn.
# The warm client applies the identical `exemptSoftCap` in `tryWarm`, so the two
# engines cannot disagree on which files `-l` returns.
#
# Usage: bench/gates/enum_determinism.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$(cd "${HERE}/../../../.." && pwd)" # contract/ → gates/ → conformance/ → bench/ → this repo root
export GIST_NO_AUTOSERVE=1                  # force the cold engine (the path under test)

echo "building gist (ReleaseFast)…"
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast > /dev/null 2>&1) || {
  echo "  build failed (engine may be mid-refactor by a coworker) — aborting"
  exit 1
}
GIST="${KERNEL}/zig-out/bin/gist"
[[ -x "${GIST}" ]] || {
  echo "  no gist binary at ${GIST}"
  exit 1
}

# The default soft cap is 100 KiB (~25k tokens); enumeration output must clear it
# for the exemption to be under test. Half the files carry the needle (so `-l`
# and `--files-without-match` are both large non-trivial sets); long nested paths
# reach the byte budget with a modest file count.
SOFT_CAP=$((100 << 10))
NEEDLE="needle_alpha_marker"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cd "${WORK}" || exit 1
git init -q . 2> /dev/null || true # a repo so the rg-compat walk honors defaults

echo "minting corpus (half carry the needle; enumeration output > ${SOFT_CAP} B)…"
for b in $(seq -w 1 60); do
  d="src/enum_determinism_corpus/bucket_${b}"
  mkdir -p "${d}"
  for f in $(seq -w 1 80); do
    n=$((10#${b} * 80 + 10#${f}))
    if ((n % 2 == 0)); then
      printf 'package p\nconst %s = 1;\nfn carrier() void {}\n' "${NEEDLE}" \
        > "${d}/carrier_file_${f}.zig"
    else
      printf 'package p\nfn noise_%s() void {}\n' "${f}" \
        > "${d}/noise_file_${f}.zig"
    fi
  done
done

# Query drivers. Cold engine, no index. `< /dev/null` keeps stdin clean; the
# coaching channel (`GIST_HINTS`) rides stderr and is discarded here.
capped() { GIST_HINTS=0 "${GIST}" "$@" --no-index -- . < /dev/null 2> /dev/null; }
uncap() { GIST_UNCAP=1 GIST_HINTS=0 "${GIST}" "$@" --no-index -- . < /dev/null 2> /dev/null; }
norm() { LC_ALL=C sort; }

fails=0

# ── positive control: the cap is LIVE on this corpus ─────────────────────────
# A content mode (default line search) is NOT exempt, so under the default cap it
# must truncate to a strict prefix of its uncapped self. If it doesn't, the
# corpus never trips the guard and every "complete" below would be vacuous.
cap_bytes=$(capped "${NEEDLE}" | wc -c | tr -d ' ')
unc_bytes=$(uncap "${NEEDLE}" | wc -c | tr -d ' ')
echo
echo "### positive control — soft cap is live ###"
if ((unc_bytes > SOFT_CAP && cap_bytes < unc_bytes)); then
  printf "  ok    content mode truncates (%s B capped ⊊ %s B uncapped, soft=%s B)\n" \
    "${cap_bytes}" "${unc_bytes}" "${SOFT_CAP}"
else
  printf "  FAIL  cap not exercised (capped=%s uncapped=%s soft=%s) — test would be vacuous\n" \
    "${cap_bytes}" "${unc_bytes}" "${SOFT_CAP}"
  fails=$((fails + 1))
fi

# ── the gate: every enumeration mode is COMPLETE and STABLE under the cap ─────
chk() {
  local label="$1"
  shift
  local u c a b
  u="$(uncap "$@" | norm)"
  c="$(capped "$@" | norm)"
  local n_full n_cap
  n_full=$(printf '%s\n' "${u}" | grep -c .)
  n_cap=$(printf '%s\n' "${c}" | grep -c .)
  if [[ "${c}" != "${u}" ]]; then
    printf "  FAIL  %-22s INCOMPLETE under cap (%s of %s lines)\n" "${label}" "${n_cap}" "${n_full}"
    diff <(printf '%s' "${u}") <(printf '%s' "${c}") | head -8 | sed 's/^/        /'
    fails=$((fails + 1))
    return
  fi
  # STABLE: three more back-to-back default-cap runs, sorted, all identical.
  a="$(capped "$@" | norm)"
  b="$(capped "$@" | norm)"
  if [[ "${a}" != "${c}" || "${b}" != "${c}" ]]; then
    printf "  FAIL  %-22s NONDETERMINISTIC set across runs\n" "${label}"
    fails=$((fails + 1))
    return
  fi
  printf "  ok    %-22s complete + stable (%s lines)\n" "${label}" "${n_full}"
}

echo
echo "### enumeration modes — complete + stable under the default cap ###"
chk "files-with (-l)" -l "${NEEDLE}"
chk "count (-c)" -c "${NEEDLE}"
chk "count-matches" --count-matches "${NEEDLE}"
chk "files-without" --files-without-match "${NEEDLE}"
chk "files (pattern-free)" --files

echo
if [[ "${fails}" -eq 0 ]]; then
  echo "PROVEN: with the soft cap live, every enumeration mode returns the complete, run-to-run-stable set — the exemption holds and never regresses to a truncated subset."
else
  echo "FAILED: ${fails} check(s) — an enumeration mode is truncating or nondeterministic under the cap. See above."
  exit 1
fi
