#!/usr/bin/env bash
# corpus-partition parity — the permanent guard for `--docs` / `--code` / `--data`.
#
# The Zig suite proves the CLASSIFIER: `genus_test.zig` walks every glob in the
# 223-row type table and checks each one lands in the genus its row declares. That
# is a statement about spellings. It cannot make the statement an agent actually
# relies on, which is about a TREE:
#
#   every file the walk produced belongs to exactly one genus, and asking for one
#   genus returns neither less nor more than that.
#
# The distance between those two is where a real regression lives. A type row
# added without a genus, a doc-location rule that stops promoting, a `--no-`
# polarity that drifts from its positive — each one leaves `genus_test` green and
# silently drops files from `--docs`. That is the same failure class
# `patterns_corpus_parity.sh` exists for, and it is worse here: an agent that
# greps the paper trail and gets 90% of it has no way to notice.
#
# So this gate asks gist about gist, over the live corpus, per needle:
#
#   TOTAL        docs ∪ code ∪ data  ==  the unfiltered answer
#   DISJOINT     every pairwise intersection is empty
#   COMPLEMENT   --no-X  ==  unfiltered − X, for each genus
#   ALIAS        -t X == --X   and   -T X == --no-X
#   INDEX-BLIND  armed == stripped: the index may elide reads, never decide the set
#   WARM≡COLD    a resident daemon answers byte-identically to a fresh process
#   NEVER UNHIDES no genus surfaces a path the unfiltered walk refused (.git/ etc.)
#
# Two non-vacuity floors, because every check above would pass against a much
# stupider classifier:
#   * all three genera must claim files, or "total and disjoint" is trivially true
#     of a partition that puts everything in one bucket;
#   * at least one EXTENSIONLESS path promoted by location or name (docs/, man/,
#     CHANGELOG) must land in docs — that rule is the whole reason this axis beats
#     a hand-assembled `-t` union, and it is the first thing a refactor loses.
#
# Self-referential on purpose: no ripgrep column. rg cannot express this axis
# (its type globs are basename-only, so a `docs/` rule is not writable there), so
# there is no oracle to borrow — the invariants ARE the specification.
#
# Usage: bench/conformance/gates/parity/partition_parity.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../apparatus/roots.sh
source "${HERE}/../../../apparatus/roots.sh"
gist_resolve_roots "${HERE}" || exit 1

echo "building gist (ReleaseFast)…"
(cd "${PRODUCT}" && zig build -Doptimize=ReleaseFast > /dev/null 2>&1) || {
  echo "FAILED: build error in ${PRODUCT}" >&2
  exit 1
}
GIST="${PRODUCT}/zig-out/bin/gist"
[[ -x "${GIST}" ]] || {
  echo "FAILED: missing ${GIST}" >&2
  exit 1
}

WORK="$(mktemp -d)"
# A PRIVATE index home, which is also a private daemon: the socket lives beside
# the index, so nothing here can disturb (or be answered by) the daemons the
# coworking agents in this tree have resident.
PRIVATE_DIR="${WORK}/gistdir"
EMPTY_DIR="${WORK}/nogistdir"
mkdir -p "${PRIVATE_DIR}" "${EMPTY_DIR}"
DAEMON_PID=""
cleanup() {
  [[ -n "${DAEMON_PID}" ]] && kill "${DAEMON_PID}" 2> /dev/null
  rm -rf "${WORK}"
}
trap cleanup EXIT

# A truncated list is a wrong list, and every check here is a set comparison.
export GIST_UNCAP=1
# Never let a persisted charter or one reader's preferences decide what the
# corpus is while a gate is judging totality over it.
export GIST_NO_CONFIG=1

GENERA=(docs code data)
fails=0
# Checks whose PRECONDITION was absent — counted separately from failures so the
# closing verdict can say what it did not look at instead of implying it passed.
skips=0
note() { printf "  %-6s %-26s %s\n" "$1" "$2" "${3-}"; }

# Lines in a file, as a bare number. Assigned rather than interpolated at every
# call site, so a failing `wc` is a failing gate instead of an empty string.
count() { wc -l < "$1" | tr -d ' '; }

# One `gist -l` file set, sorted, into $1. Remaining args are gist's.
setof() {
  local dst="$1"
  shift
  (cd "${REPO}" && "${GIST}" -l "$@" < /dev/null 2> /dev/null) | LC_ALL=C sort -u > "${dst}"
}

# ── the corpus, per needle ───────────────────────────────────────────────────
# Needles are chosen to resolve in all three genera at once: a word that appears
# in prose, in implementation, and in configuration. A needle that only ever hits
# code would make the docs columns vacuous without failing anything.
NEEDLES=(gist version license)

for needle in "${NEEDLES[@]}"; do
  echo
  echo "needle '${needle}'"
  all="${WORK}/all"
  setof "${all}" "${needle}"
  n_all="$(count "${all}")"
  if [[ "${n_all}" -eq 0 ]]; then
    note FAIL "unfiltered" "matched 0 files — a vacuous needle proves nothing"
    fails=$((fails + 1))
    continue
  fi

  # positives, negatives, and their aliases
  empty_genus=0
  for g in "${GENERA[@]}"; do
    setof "${WORK}/pos.${g}" "--${g}" "${needle}"
    setof "${WORK}/neg.${g}" "--no-${g}" "${needle}"
    setof "${WORK}/alias.${g}" -t "${g}" "${needle}"
    setof "${WORK}/nalias.${g}" -T "${g}" "${needle}"
    [[ -s "${WORK}/pos.${g}" ]] || empty_genus=$((empty_genus + 1))
  done

  # TOTAL — the three genera reassemble the unfiltered answer exactly.
  LC_ALL=C sort -u "${WORK}/pos.docs" "${WORK}/pos.code" "${WORK}/pos.data" > "${WORK}/union"
  if cmp -s "${all}" "${WORK}/union"; then
    note ok "total" "${n_all} files = docs+code+data"
  else
    note FAIL "total" "docs+code+data != unfiltered (${n_all} files)"
    diff "${all}" "${WORK}/union" | head -4 | sed 's/^/          /'
    fails=$((fails + 1))
  fi

  # DISJOINT — no path may answer to two genera.
  for pair in "docs code" "docs data" "code data"; do
    read -r a b <<< "${pair}"
    comm -12 "${WORK}/pos.${a}" "${WORK}/pos.${b}" > "${WORK}/both"
    if [[ -s "${WORK}/both" ]]; then
      n_both="$(count "${WORK}/both")"
      note FAIL "disjoint ${a}/${b}" "${n_both} paths claimed by both"
      head -3 "${WORK}/both" | sed 's/^/          /'
      fails=$((fails + 1))
    fi
  done

  # COMPLEMENT — `--no-X` is exactly what `--X` left behind.
  for g in "${GENERA[@]}"; do
    comm -23 "${all}" "${WORK}/pos.${g}" > "${WORK}/expect.neg"
    if cmp -s "${WORK}/expect.neg" "${WORK}/neg.${g}"; then
      n_neg="$(count "${WORK}/neg.${g}")"
      note ok "complement --no-${g}" "${n_neg} files"
    else
      note FAIL "complement --no-${g}" "--no-${g} != unfiltered - --${g}"
      diff "${WORK}/expect.neg" "${WORK}/neg.${g}" | head -4 | sed 's/^/          /'
      fails=$((fails + 1))
    fi
  done

  # ALIAS — a genus is a type name, so both spellings must be one answer.
  for g in "${GENERA[@]}"; do
    cmp -s "${WORK}/pos.${g}" "${WORK}/alias.${g}" || {
      note FAIL "alias -t ${g}" "-t ${g} != --${g}"
      fails=$((fails + 1))
    }
    cmp -s "${WORK}/neg.${g}" "${WORK}/nalias.${g}" || {
      note FAIL "alias -T ${g}" "-T ${g} != --no-${g}"
      fails=$((fails + 1))
    }
  done

  # NEVER UNHIDES — a genus narrows the walk's output; it cannot re-admit what
  # the walk refused. `code` is the default direction, so the bug this catches is
  # a real one that shipped once: unrecognized ⇒ code made `--code` whitelist
  # every hidden path, and .git/ came back.
  for g in "${GENERA[@]}"; do
    comm -13 "${all}" "${WORK}/pos.${g}" > "${WORK}/extra"
    if [[ -s "${WORK}/extra" ]]; then
      note FAIL "no-unhide --${g}" "--${g} surfaced paths the unfiltered walk refused"
      head -3 "${WORK}/extra" | sed 's/^/          /'
      fails=$((fails + 1))
    fi
  done

  if [[ "${empty_genus}" -gt 0 ]]; then
    note FAIL "non-vacuous" "${empty_genus} genus/genera claimed no file for this needle"
    fails=$((fails + 1))
  fi
done

# ── INDEX-BLIND — the index elides reads; the walk owns the population ───────
echo
echo "the index may accelerate a genus query, never decide it"
setof "${WORK}/armed" --docs gist
(cd "${REPO}" && GIST_DIR="${EMPTY_DIR}" "${GIST}" -l --docs gist < /dev/null 2> /dev/null) \
  | LC_ALL=C sort -u > "${WORK}/stripped"
if cmp -s "${WORK}/armed" "${WORK}/stripped"; then
  n_armed="$(count "${WORK}/armed")"
  note ok "armed == stripped" "${n_armed} files either way"
else
  note FAIL "armed == stripped" "an empty GIST_DIR changed which files answered"
  diff "${WORK}/armed" "${WORK}/stripped" | head -4 | sed 's/^/          /'
  fails=$((fails + 1))
fi

# ── WARM ≡ COLD — the daemon carries the selection, or declines to cold ──────
# The genus rides the query_ext frame as a two-byte trailer. If that encoding
# ever drifts the daemon answers a DIFFERENT question at warm speed, which is the
# worst available outcome: fast and wrong, with no error.
echo
echo "a resident session answers the same question"
(cd "${REPO}" && GIST_DIR="${PRIVATE_DIR}" "${GIST}" index > /dev/null 2>&1) || {
  note FAIL "warm" "could not build a private index"
  fails=$((fails + 1))
}
# One session per spec, deliberately. A daemon is a long-lived process this gate
# does not own the health of: if it dies mid-slate, a shared one would answer the
# first spec warm and quietly hand the rest to the cold path, which is the one
# failure mode that would make every remaining row a comparison of cold with
# itself. Re-arming is a couple of seconds over a prebuilt index and buys a slate
# where each row's warmth is independently true.
serve() {
  # The daemon is single-instance behind an exclusive lock on `<socket>.lock`, so
  # a successor that starts before its predecessor has actually exited loses the
  # race and returns at once — reaping is part of asking for a new one, not
  # tidiness.
  if [[ -n "${DAEMON_PID}" ]]; then
    kill "${DAEMON_PID}" 2> /dev/null || true
    wait "${DAEMON_PID}" 2> /dev/null || true
  fi
  rm -f "${PRIVATE_DIR}/gistd.sock"
  # `exec` so the recorded pid IS the daemon: a plain `( … ) &` records the
  # subshell, and killing that leaves the real `gist serve` holding the
  # single-instance lock while every successor declines.
  (cd "${REPO}" && GIST_DIR="${PRIVATE_DIR}" exec "${GIST}" serve > "${WORK}/serve.log" 2>&1) &
  DAEMON_PID=$!
  for _ in $(seq 1 100); do
    [[ -S "${PRIVATE_DIR}/gistd.sock" ]] && return 0
    sleep 0.1
  done
  return 1
}

warm_served=0
# Absence has two causes and only one of them is this feature's: a session that
# never came up or died under the query (the daemon's health, gated elsewhere),
# versus a live session that answered cold anyway (genus lost its eligibility).
no_session=0
declined=0
for spec in "--docs" "--code" "--no-docs" "--docs --data"; do
  if ! serve; then
    # A resident tier that will not START is a precondition, not a partition
    # violation — there is no second answer, so there is nothing to be wrong
    # about. Failing it would blame this feature for the daemon's own health,
    # which the serve tests and the session lane already own. The two ways a
    # genus could really break warm both stay fatal: a daemon that answers a
    # DIFFERENT set, and a daemon that serves NONE of the slate warm.
    why="$(tail -n 1 "${WORK}/serve.log" 2> /dev/null)" || why=""
    note "SKIP" "warm '${spec}'" "no session here — ${why:-no output}"
    no_session=$((no_session + 1))
    continue
  fi
  # shellcheck disable=SC2086 # $spec is a deliberate flag list
  # The answer keep is off for the same reason the timing lane turns it off: a
  # recalled answer is rendered bytes replayed by key, so it would prove the KEY
  # carries the genus and leave the searching side unexamined.
  (cd "${REPO}" && GIST_DIR="${PRIVATE_DIR}" GIST_NO_KEEP=1 GIST_TRACE=warm GIST_TRACE_FORMAT=text \
    "${GIST}" -l ${spec} gist < /dev/null 2> "${WORK}/warm.err") \
    | LC_ALL=C sort -u > "${WORK}/warm.out"
  # shellcheck disable=SC2086
  (cd "${REPO}" && GIST_DIR="${PRIVATE_DIR}" GIST_NO_AUTOSERVE=1 \
    "${GIST}" -l --no-index ${spec} gist < /dev/null 2> /dev/null) \
    | LC_ALL=C sort -u > "${WORK}/cold.out"
  if ! cmp -s "${WORK}/warm.out" "${WORK}/cold.out"; then
    note FAIL "warm '${spec}'" "the resident session answered a different question"
    diff "${WORK}/warm.out" "${WORK}/cold.out" | head -4 | sed 's/^/          /'
    fails=$((fails + 1))
  elif grep -qi 'warm\|session\|resident' "${WORK}/warm.err"; then
    # Warm must have actually been warm for the row to mean anything; a silently
    # cold run would make this a comparison of cold with itself.
    warm_served=$((warm_served + 1))
    n_warm="$(count "${WORK}/warm.out")"
    note ok "warm '${spec}'" "${n_warm} files, served warm"
  elif kill -0 "${DAEMON_PID}" 2> /dev/null; then
    # The socket was there, the daemon is STILL there, and the answer came cold
    # anyway. That is a decline, and a decline is about genus eligibility.
    note "-" "warm '${spec}'" "equal, but a live session declined it to cold"
    declined=$((declined + 1))
  else
    note "SKIP" "warm '${spec}'" "equal, but the session died under the query"
    no_session=$((no_session + 1))
  fi
done
if [[ "${warm_served}" -eq 0 ]]; then
  # Nothing was served warm at all. If a live session declined every spec, genus
  # lost its daemon eligibility and that must not pass quietly. If no session
  # ever survived to answer, there was nothing to be eligible for.
  if [[ "${no_session}" -eq 0 ]]; then
    echo
    echo "FAILED: a live session declined all ${declined} genus queries, so the warm"
    echo "        rows above compared the cold path with itself. Genus is"
    echo "        supposed to be daemon-eligible (query_ext trailer); if that was"
    echo "        deliberately withdrawn, this gate must be rewritten, not passed."
    fails=$((fails + 1))
  else
    skips=$((skips + 1))
    echo "          (the wire trailer stays unproven until a session survives a query)"
  fi
fi

# ── NON-VACUITY — the location rule is alive ─────────────────────────────────
# `--docs` earns its keep on the files a `-t` union cannot name: a document with
# no extension, promoted because of where it lives or what it is called. If this
# ever comes back empty, `--docs` has quietly degenerated into `-t markdown`
# and every check above still passes.
echo
echo "extensionless documents are still promoted by location or name"
(cd "${REPO}" && "${GIST}" --files --docs < /dev/null 2> /dev/null) \
  | grep -Ev '\.[A-Za-z0-9]+$' > "${WORK}/extensionless" || true
n_ext="$(count "${WORK}/extensionless")"
if [[ "${n_ext}" -eq 0 ]]; then
  note FAIL "promoted docs" "no extensionless path is classified as docs"
  fails=$((fails + 1))
else
  note ok "promoted docs" "${n_ext} extensionless documents"
  head -3 "${WORK}/extensionless" | sed 's/^/          e.g. /'
fi

echo
if [[ "${fails}" -eq 0 ]]; then
  accel="the index changes"
  [[ "${warm_served}" -gt 0 ]] && accel="the index and the resident session change"
  echo "PROVEN: over this tree, the three genera are total and disjoint; every"
  echo "        --no- form is its positive's exact complement; -t/-T agree with"
  echo "        the long flags; ${accel} speed and nothing else;"
  echo "        no genus un-hides a path the walk refused; and the location rule"
  echo "        still rescues extensionless documents."
  # A verdict that reads as unconditional while a check never ran is how a gate
  # becomes decoration, so the skip is repeated in the last thing anyone reads.
  if [[ "${skips}" -gt 0 ]]; then
    echo "        NOT checked here: ${skips} precondition-less check(s) — see SKIP above."
  fi
else
  echo "FAILED: ${fails} invariant(s) broken. These are properties of the"
  echo "        partition, not of this script — fix genus.zig, the filters, or"
  echo "        the wire trailer. An agent asking for the paper trail and"
  echo "        silently getting most of it is the outcome this gate prevents."
  exit 1
fi
