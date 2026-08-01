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
# rg-parity walk. Measured before the fix, on a large polyglot monorepo:
# `relate patterns -F -e graphify` reported 145 files where `gist -F -l graphify`
# reported 616 — every one of the 471 missing files under one vendored subtree,
# silently, on a verb whose entire purpose is EXACT per-pattern attribution.
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
# resolve under a `isSkipDir`-pruned directory, or the gate fails as vacuous —
# that is the exact blind spot it exists to keep closed.
#
# Usage: bench/conformance/gates/parity/patterns_corpus_parity.sh
#
# A package measuring itself supplies NONE of the corpus properties below, and
# it fails on every one of them at once: it has no pruned subtree, so the two
# root-scoped cases and the non-vacuity check at the bottom all come up empty —
# and the default slate's patterns are facts about a particular monorepo too, so
# the cases naming tools that tree happens to ship find nothing either. Each is
# its own loud FAIL, BY DESIGN; a pattern nobody matches proves nothing about
# population, so it is never quietly skipped.
#
# This repo ships a corpus that does supply them — generated deterministically
# by `bench/apparatus/corpora/torture.py`, no network, no private tree:
#
#   bench/apparatus/corpora/fetch.sh torture
#   (cd .local/gist-corpora/torture && gist index)   # so the armed leg is armed
#   GIST_CORPUS_ROOT="$PWD/.local/gist-corpora/torture" GIST_PARITY_SLATE=torture \
#     bench/conformance/gates/parity/patterns_corpus_parity.sh
#
# Any other tree works the same way: name its two roots and hand it a slate.
set -uo pipefail

# ── the corpus properties this gate is TOLD, not ones it assumes ──────────────
# The corpus is an INPUT here, and this is the one gate that constrains it. Both
# paths below used to be literals baked into the logic, which meant the gate
# could only ever run against one particular tree and carried that tree's layout
# around in its source. They are declared inputs now; nothing else about the
# gate's semantics moved.
#
# GIST_PARITY_PRUNED_ROOT — a path, relative to the corpus root, that
#   `haystack.isSkipDir` prunes out of the corpus loader while the rg-parity walk
#   still ENTERS it. That asymmetry is the entire instrument: it is the only
#   place the two populations can disagree, which is why the non-vacuity check
#   at the bottom demands hits under it.
#
#   `vendor` by default — one of the generic cross-ecosystem basenames in
#   haystack.zig's comptime skip set, and of those the one most likely to hold
#   committed source a walk really sees: Go module vendoring, Composer, Bundler
#   and `cargo vendor` all put third-party code in `vendor/`, normally checked
#   in. `node_modules` is pruned identically but is almost always gitignored,
#   which takes it out of the rg-parity walk too — and then BOTH sides agree for
#   the wrong reason and the gate proves nothing. Naming a directory in the
#   tree's charter `skip` or in `GIST_SKIP` is the same trap and worse: cold
#   search honors those deliberately, so such a path is invisible to both sides.
#   Whatever is declared here has to be pruned by the BASELINE set and still be
#   visible to the walk, or the run is vacuous however green it looks.
#
# GIST_PARITY_SCOPE_ROOT — an ordinary path that is NOT pruned, for the second
#   root-scoped case, so the pair covers both sides of the skip decision. `src`
#   by default: the most common source-directory convention there is, and
#   deliberately not a name `isSkipDir` touches.
PRUNED_ROOT="${GIST_PARITY_PRUNED_ROOT:-vendor}"
SCOPE_ROOT="${GIST_PARITY_SCOPE_ROOT:-src}"

# GIST_PARITY_SLATE — the cases themselves. The two roots above say WHERE to
#   look; the slate says WHAT to look for, and a pattern is every bit as much a
#   fact about the corpus as a path is. These were still literals in the logic
#   after the roots were lifted, two of them tool names from the monorepo this
#   gate was built against — so a tree could declare both roots correctly and
#   still not be able to run the gate, which is half a knob.
#
#   Rows are `<label> <pattern> [<scope>]`, whitespace-separated: the same row
#   shape every `PROBES` array under `bench/` uses, under the same constraint —
#   a pattern containing whitespace is not expressible. A row with no scope
#   searches the whole corpus; the last column absorbs the rest of the line.
#
#   The value is either the NAME of a slate declared below (`monorepo`,
#   `torture`) or a literal slate — newline-separated rows, blank lines and
#   whole-line `#` comments allowed — so a third corpus needs no edit here.
#
#   WHAT A REPLACEMENT SLATE HAS TO SUPPLY. The spread is the coverage
#   argument, not decoration. Six roles; drop one and the gate stops proving
#   what its name claims:
#     · a literal whose hits are DOMINATED by the pruned tree — the regression
#       case, the one that was silently wrong (145 files reported of 616);
#     · a second resident of that tree in a different shape (an underscored
#       identifier), so the first is not one token's coincidence;
#     · ordinary first-party literals OUTSIDE the pruned tree, which catch the
#       opposite failure — a fix that over-corrects into a population that is
#       not gist's for the normal case;
#     · a 3-character pattern: exactly one trigram, the narrowest thing the
#       index can prefilter on;
#     · one case scoped to the pruned root and one scoped to the plain root, so
#       both sides of the skip decision are covered and a post-hoc scope filter
#       (rather than the walk being the scope authority) would show up.

# The slate for the large polyglot monorepo this gate was built against and
# where it caught the defect. Kept as the default because that lane still runs
# it; nothing outside that tree matches these, which is what `torture` is for.
SLATE_MONOREPO=(
  # The regression case: a literal whose hits are dominated by a pruned tree.
  # This is the one that was silently wrong.
  "pruned-literal graphify"
  # Resident in the pruned tree too, and a different shape (underscored identifier).
  "pruned-underscore build_graph"
  # Ordinary first-party literals: prove the fix didn't over-correct into a
  # different population than gist's for the normal case.
  "first-party-py doc_radar"
  "first-party-zig PatternSet"
  "short-3char cfg"
  # Root-scoped: the walk is the scope authority, so an explicit root must
  # narrow both sides identically. Once with a root isSkipDir prunes — naming a
  # skipped directory AS a root still searches it — and once with a root it does
  # not, so both sides of the skip decision are covered.
  "root-scoped-pruned graphify ${PRUNED_ROOT}"
  "root-scoped-plain Muster ${SCOPE_ROOT}"
)

# The hermetic slate: the same six roles over the committed `vendor/` and `src/`
# subtrees `bench/apparatus/corpora/torture.py` plants. That generator and these
# rows are one coupled pair — the tokens are named in both, and nothing
# machine-enforces it beyond the corpora README's doc-radar sentinel, so a
# rename there must land here in the same commit.
SLATE_TORTURE=(
  # Dominated by vendor/ (every vendored file names it) with a handful of
  # callers in src/ — the same silhouette the monorepo's regression case had.
  "pruned-literal hexdrift"
  # Same tree, underscored-identifier shape.
  "pruned-underscore hexdrift_encode"
  # First-party only: neither appears anywhere under the pruned tree.
  "first-party-snake ledger_entry"
  "first-party-camel LedgerEntry"
  # Exactly one trigram, and deliberately resident on BOTH sides of the skip
  # decision so a dropped population shows up as a short count, not an empty one.
  "short-3char cfg"
  # Root-scoped, both sides of the skip decision (see the monorepo slate above).
  "root-scoped-pruned hexdrift ${PRUNED_ROOT}"
  "root-scoped-plain LedgerEntry ${SCOPE_ROOT}"
)

SLATE="${GIST_PARITY_SLATE:-monorepo}"
CASES=()
if [[ "${SLATE}" == monorepo ]]; then
  CASES=("${SLATE_MONOREPO[@]}")
elif [[ "${SLATE}" == torture ]]; then
  CASES=("${SLATE_TORTURE[@]}")
else
  # A literal slate. Default IFS on a single `read` target trims each row's ends
  # without touching its columns, so an indented override reads the same as a
  # flush one.
  while read -r row; do
    if [[ -n "${row}" && "${row}" != '#'* ]]; then
      CASES+=("${row}")
    fi
  done <<< "${SLATE}"
fi

if [[ "${#CASES[@]}" -eq 0 ]]; then
  echo "FAILED: GIST_PARITY_SLATE named no cases. A gate with no cases is not a" >&2
  echo "        passing gate; supply rows rather than an empty slate." >&2
  exit 1
fi

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
pruned_proven=0

# `--by file` rows are `<count>\tab<path>`; the file SET is the path column.
paths_of_patterns() {
  sed 's/^[0-9]*[[:space:]]*//' | LC_ALL=C sort -u
}

# How many of an oracle's paths live UNDER the declared pruned root — the count
# the non-vacuity check turns on. Every path gets a leading `/` first so one
# fixed-string match tests a whole path COMPONENT: a hardcoded two-component
# literal made a bare substring close enough, but a declared root can be a single
# generic word, and then `vendor.zig` or `bench/myvendor/x` would count as a hit
# under a pruned tree and satisfy the check without one. `-F` because a legitimate
# value carries regex metacharacters (`.venv`, `.git`).
#
# `grep -c` prints its count and then exits 1 when that count is zero, and under
# `pipefail` that status is the pipeline's. Zero here is a perfectly legitimate
# answer — it is the reading the non-vacuity check exists to act on — so the
# status is discarded deliberately. Today the script has no `set -e` and the
# stray rc=1 is inert; discarding it is what keeps adding one later from turning
# every no-pruned-hit case into a run-killer. The count itself is unchanged.
pruned_hits() {
  sed 's,^,/,' "$1" | grep -F -c "/${PRUNED_ROOT}/" || true
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

  local n_oracle n_pruned
  n_oracle=$(wc -l < "${WORK}/.oracle" | tr -d ' ')
  n_pruned=$(pruned_hits "${WORK}/.oracle")

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

  if [[ "${n_pruned}" -gt 0 ]]; then
    pruned_proven=$((pruned_proven + 1))
    printf "  ok    %-24s %s files (%s under %s/)\n" "${label}" "${n_oracle}" "${n_pruned}" "${PRUNED_ROOT}"
  else
    printf "  ok    %-24s %s files\n" "${label}" "${n_oracle}"
  fi
}

echo
echo "relate patterns file set  ==  gist -l file set   (index armed AND stripped)"
# The armed leg is only ARMED if the corpus actually carries an index. Without
# one, both legs run stripped and half the headline claim goes unproven — so the
# gate refuses rather than reporting a half-vacuous run as a pass. It still never
# BUILDS an index: it must not write into a tree it was merely handed.
if [[ ! -f "${GIST_VERIFY}/index.gist" ]]; then
  echo "FAILED: no index at ${GIST_VERIFY}, so both legs would run stripped and the" >&2
  echo "        armed half of this gate's claim would go unproven. Run \`gist index\`" >&2
  echo "        inside the corpus, then re-run; this gate will not write to it." >&2
  exit 1
fi
echo "index: ${GIST_VERIFY}/index.gist"
echo

for row in "${CASES[@]}"; do
  read -r label pat scope <<< "${row}"
  if [[ -z "${pat}" ]]; then
    printf "  FAIL  %-24s malformed row, want '<label> <pattern> [<scope>]'\n" "${label:-<unlabelled>}"
    fails=$((fails + 1))
    continue
  fi
  if [[ -n "${scope}" ]]; then
    chk "${label}" "${pat}" "${scope}"
  else
    chk "${label}" "${pat}"
  fi
done

echo
if [[ "${pruned_proven}" -eq 0 ]]; then
  echo "FAILED: no case resolved under an isSkipDir-pruned tree (${PRUNED_ROOT}/)."
  echo "        The gate cannot prove the population is rg-parity without one —"
  echo "        it would pass just as happily against the pruned corpus it exists"
  echo "        to reject. Supply the missing corpus property rather than deleting"
  echo "        this check. What is missing: a directory whose basename"
  echo "        haystack.isSkipDir prunes (the generic VCS/build/vendor set) that"
  echo "        the rg-parity walk still enters — so committed, not gitignored,"
  echo "        and not named in the tree's charter skip or GIST_SKIP — holding"
  echo "        files that match one of the patterns above."
  echo
  echo "        This repo generates a corpus that has one, offline:"
  echo "          bench/apparatus/corpora/fetch.sh torture"
  echo "          GIST_CORPUS_ROOT=<…>/.local/gist-corpora/torture \\"
  echo "            GIST_PARITY_SLATE=torture \\"
  echo "            bench/conformance/gates/parity/patterns_corpus_parity.sh"
  echo
  echo "        For any other tree, name its properties instead:"
  echo "          GIST_CORPUS_ROOT=<a tree with such a subtree> \\"
  echo "            GIST_PARITY_PRUNED_ROOT=${PRUNED_ROOT} \\"
  echo "            GIST_PARITY_SCOPE_ROOT=${SCOPE_ROOT} \\"
  echo "            GIST_PARITY_SLATE=<one '<label> <pattern> [<scope>]' row per line> \\"
  echo "            bench/conformance/gates/parity/patterns_corpus_parity.sh"
  exit 1
fi

if [[ "${fails}" -eq 0 ]]; then
  echo "PROVEN: relate patterns answers over the same file set as N sequential"
  echo "        gist -l runs, index armed AND stripped — including ${pruned_proven} case(s)"
  echo "        whose hits live under the pruned ${PRUNED_ROOT}/ tree. The index"
  echo "        accelerates the read; the walk alone decides the population."
else
  echo "FAILED: ${fails} case(s) diverged — relate patterns is not a drop-in for"
  echo "        gist -l. An exact verb that silently drops files is the bug this"
  echo "        gate exists to catch; fix the population, never this gate."
  exit 1
fi
