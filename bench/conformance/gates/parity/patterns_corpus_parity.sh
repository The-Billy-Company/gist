#!/usr/bin/env bash
# relate patterns corpus parity — the permanent guard for the multi-pattern
# surface's contract: `relate patterns` is a DROP-IN for N sequential `gist -l`
# runs, so it must answer over the same population.
#
# This is the relate-side twin of `index_elision_parity.sh`. That gate proves
# the trigram index is an acceleration structure for `gist`, never a semantic
# one — the walk stays the sole authority on the file set. `patterns` used to
# violate exactly that law from the other direction: it took its POPULATION from
# the corpus loader (`corpus/tree/corpus.zig`, which prunes the generic
# VCS/build/vendor basenames via `haystack.isSkipDir`) instead of from the
# rg-parity walk. Measured before the fix: `relate patterns -F -e graphify`
# reported 145 files where `gist -F -l graphify` reported 616 — every one of the
# 471 missing files under `scripts/vendor`, silently, on a verb whose entire
# purpose is EXACT per-pattern attribution.
#
# That pruning is right for the kinship verbs and deliberately left alone:
# `similar`/`echoes`/`pack` are statistical, and a vendored tree should not
# dominate compression scores. It is wrong for an exact verb. So `patterns` now
# walks through `quarry/walk.zig` — literally the enumerator `gist` uses — and
# consults the index only to elide READS.
#
# The gate therefore asserts, per pattern:
#   relate patterns -F -e P --by file   ==(file set)==   gist -F -l P
# both with the index armed and with it stripped (empty GIST_DIR), because an
# index must never be able to change which files answer. At least one case must
# resolve under a `isSkipDir`-pruned directory (`scripts/vendor`), or the gate
# fails as vacuous — that is the exact blind spot it exists to keep closed.
#
# Usage: bench/gates/patterns_corpus_parity.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../apparatus/roots.sh
source "${HERE}/../../../apparatus/roots.sh"
gist_resolve_roots "${HERE}" || exit 1

echo "building gist + relate (ReleaseFast)…"
# Two checkouts since the split: `relate` ships its own binary from its own
# package, so one zig-out no longer holds both.
for root in "${PRODUCT}" "${KINSHIP}"; do
  (cd "${root}" && zig build -Doptimize=ReleaseFast > /dev/null 2>&1) || {
    echo "FAILED: build error in ${root}" >&2
    exit 1
  }
done
GIST="${PRODUCT}/zig-out/bin/gist"
RELATE="${KINSHIP}/zig-out/bin/relate"
for bin in "${GIST}" "${RELATE}"; do
  [[ -x "${bin}" ]] || {
    echo "FAILED: missing ${bin}" >&2
    exit 1
  }
done

WORK="$(mktemp -d)"
EMPTY_GIST_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK}" "${EMPTY_GIST_DIR}"' EXIT

# Lift the soft output cap so a wide pattern's file list is never truncated on
# one side of the diff (the hard OOM ceiling stays on).
export GIST_UNCAP=1
# `patterns` is one of the seven pure verbs that consult a resident daemon's
# answer keep. A recalled answer is byte-identical by contract, but this gate
# must judge the CODE, not the keep, so every relate run here recomputes.
export GIST_NO_KEEP=1

fails=0
vendor_proven=0

# `--by file` rows are `<count>\tab<path>`; the file SET is the path column.
paths_of_patterns() {
  sed 's/^[0-9]*[[:space:]]*//' | LC_ALL=C sort -u
}

# One case: `relate patterns` file set vs `gist -l`, index armed and stripped.
chk() {
  local label="$1" pat="$2"
  shift 2

  (cd "${REPO}" && "${GIST}" -F -l "${pat}" "$@" < /dev/null 2> /dev/null) \
    | LC_ALL=C sort -u > "${WORK}/.oracle"
  (cd "${REPO}" && "${RELATE}" patterns -F -e "${pat}" --by file "$@" < /dev/null 2> /dev/null) \
    | paths_of_patterns > "${WORK}/.armed"
  (cd "${REPO}" && GIST_DIR="${EMPTY_GIST_DIR}" "${RELATE}" patterns -F -e "${pat}" --by file "$@" < /dev/null 2> /dev/null) \
    | paths_of_patterns > "${WORK}/.stripped"

  local n_oracle n_vendor
  n_oracle=$(wc -l < "${WORK}/.oracle" | tr -d ' ')
  n_vendor=$(grep -c 'scripts/vendor' "${WORK}/.oracle")

  # A pattern nobody matches proves nothing about population.
  if [[ "${n_oracle}" -eq 0 ]]; then
    printf "  FAIL  %-24s vacuous: gist -l found 0 files\n" "${label}"
    fails=$((fails + 1))
    return
  fi

  local bad=""
  diff -q "${WORK}/.oracle" "${WORK}/.armed" > /dev/null || bad="armed"
  diff -q "${WORK}/.oracle" "${WORK}/.stripped" > /dev/null || bad="${bad:+${bad}+}stripped"

  if [[ -n "${bad}" ]]; then
    printf "  FAIL  %-24s %s diverged from gist -l (%s files)\n" "${label}" "${bad}" "${n_oracle}"
    diff "${WORK}/.oracle" "${WORK}/.armed" | head -4 | sed 's/^/          /'
    fails=$((fails + 1))
    return
  fi

  if [[ "${n_vendor}" -gt 0 ]]; then
    vendor_proven=$((vendor_proven + 1))
    printf "  ok    %-24s %s files (%s under scripts/vendor)\n" "${label}" "${n_oracle}" "${n_vendor}"
  else
    printf "  ok    %-24s %s files\n" "${label}" "${n_oracle}"
  fi
}

echo
echo "relate patterns file set  ==  gist -l file set   (index armed AND stripped)"
echo

# The regression case: a literal whose hits are dominated by a pruned vendored
# tree. This is the one that was silently wrong.
chk "vendored-literal" graphify
# Vendor-resident too, and a different shape (underscored identifier).
chk "vendored-underscore" build_graph
# Ordinary first-party literals: prove the fix didn't over-correct into a
# different population than gist's for the normal case.
chk "first-party-py" doc_radar
chk "first-party-zig" PatternSet
chk "short-3char" cfg
# Root-scoped: the walk is the scope authority, so an explicit root must narrow
# both sides identically (this is where a post-hoc scope filter would show up).
chk "root-scoped" graphify scripts/vendor
chk "root-scoped-libs" Muster pkg/kernels

echo
if [[ "${vendor_proven}" -eq 0 ]]; then
  echo "FAILED: no case resolved under an isSkipDir-pruned tree (scripts/vendor)."
  echo "        The gate cannot prove the population is rg-parity without one —"
  echo "        it would pass just as happily against the pruned corpus it exists"
  echo "        to reject. Restore a vendored case rather than deleting this check."
  exit 1
fi

if [[ "${fails}" -eq 0 ]]; then
  echo "PROVEN: relate patterns answers over the same file set as N sequential"
  echo "        gist -l runs, index armed or stripped — including ${vendor_proven} case(s)"
  echo "        whose hits live under a pruned vendored tree. The index accelerates"
  echo "        the read; the walk alone decides the population."
else
  echo "FAILED: ${fails} case(s) diverged — relate patterns is not a drop-in for"
  echo "        gist -l. An exact verb that silently drops files is the bug this"
  echo "        gate exists to catch; fix the population, never this gate."
  exit 1
fi
