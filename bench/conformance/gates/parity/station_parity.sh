#!/usr/bin/env bash
# gist station parity — the permanent guard for searching from INSIDE a tree.
#
# One artifact home per checkout means the index, content shard, phantom
# snapshot and daemon socket a query finds from `services/ai` are the ones built
# at the tree root. That is the whole point — a subdirectory search finally gets
# to ride them — and it is also the one place a wrong answer can hide, because
# two coordinate systems now name the same file. Artifacts are written relative
# to the CHECKOUT; a walk emits paths relative to the WORKING DIRECTORY, because
# that is what rg prints. Every index-keyed lookup crosses between them
# (`corpus.home.inTree`), and a lookup that forgets does not fail loudly: it
# finds a real doc for a real path that is a DIFFERENT FILE.
#
# So the oracle here is the same one `index_elision_parity.sh` uses — gist's own
# `--no-index` full live read — asked from a subdirectory instead of the root,
# over a corpus deliberately built so that forgetting the rebase changes the
# ANSWER rather than the speed:
#
#   * same basenames at two depths with opposite content (`notes.md` holds the
#     needle at the root and not in the subtree, and vice versa), so a lookup
#     that drops the station elides a file that matches, or reads a stale shard
#     slice belonging to the root's copy;
#   * a needle that exists ONLY above the subtree, which must report no match
#     from below however much the index knows about it;
#   * a post-index edit under the subtree, so the freshness rule is exercised in
#     rebased coordinates too.
#
# Three further arms cover what the coordinate change reaches beyond lookup:
# building the index FROM a subdirectory (which must still index and name the
# whole tree), scoping a build explicitly from one (which must stay scoped and
# be named from the tree), and a resident session — the tier that renders whole
# answers, where a daemon that went resident in the subtree must never be handed
# a tree-root query. That last one is not hypothetical: it is what this gate
# caught while the coordinate work was being done.
#
# Usage: bench/conformance/gates/parity/station_parity.sh
set -uo pipefail
export GIST_UNCAP=1
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../apparatus/roots.sh
source "${HERE}/../../../apparatus/roots.sh"
gist_resolve_roots "${HERE}" || exit 1

echo "building gist (ReleaseFast)…"
(cd "${PRODUCT}" && zig build -Doptimize=ReleaseFast > /dev/null 2>&1) || {
  echo "  build failed (engine may be mid-refactor by a coworker) — aborting"
  exit 1
}
GIST="${GIST:-${PRODUCT}/zig-out/bin/gist}"
[[ -x "${GIST}" ]] || GIST+=".exe"
[[ -x "${GIST}" ]] || {
  echo "  no gist binary at ${GIST%.exe}[.exe]"
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
TREE="${WORK}/tree"
SUB="${TREE}/services/ai"
mkdir -p "${SUB}/deep" "${TREE}/libs"
cd "${TREE}" || exit 1
git init -q . 2> /dev/null || true

# The adversarial corpus. `notes.md` and `libs/notes.md` exist at three depths
# with DIFFERENT content, so every rebased lookup has a same-named decoy above
# it. `needle_above` lives only outside the subtree; `needle_below` only inside.
printf 'needle_above at the tree root\n' > notes.md
printf 'needle_above in libs\n' > libs/notes.md
printf 'needle_below in the subtree\n' > "${SUB}/notes.md"
printf 'needle_below deeper still\n' > "${SUB}/deep/notes.md"
printf 'plain text, no needles, %s\n' "$(seq 1 40 | tr '\n' ' ')" > "${SUB}/quiet.md"

# Bulk on BOTH sides of the boundary. Size is load-bearing here, not padding:
# the elide oracle is loaded CONCURRENTLY with the walk and is only consulted if
# it lands before the walk runs out of files (`exec/cold/quarry/elide.zig`). Over
# a few dozen files the walk always wins, every file is read live, and a gate
# over that corpus proves only that the live read works — it passes just as
# happily with the rebase deleted. These counts put the subtree comfortably past
# that threshold, so the tier under test is the one actually answering.
python3 - "${TREE}" <<'PY'
import os, sys
tree = sys.argv[1]
for d, n, tag in ((f"{tree}/services/ai/deep", 2500, "sub"), (f"{tree}/libs", 2500, "root")):
    os.makedirs(d, exist_ok=True)
    for i in range(n):
        with open(f"{d}/noise_{i}.md", "w") as f:
            f.write(f"{tag} noise {i} lorem ipsum dolor sit amet {{}} ()\n")
PY

# Age the corpus past the build anchor before indexing. Without this every file
# fails `bulkstat.needsLiveRead` — mtime on the anchor tick is not proof of
# being unchanged — so the elide oracle and the content shard both decline and
# every file is read live. The gate would still pass, and would be proving
# nothing: the tiers it exists to check would never have been consulted.
sleep 1

echo "indexing at the tree root…"
"${GIST}" index > /dev/null 2>&1 || {
  echo "  gist index failed"
  exit 1
}

fails=0
# One case, three arms, all run from the SUBDIRECTORY. `--no-index` is the
# oracle; the auto run is what ships; `GIST_NO_JOURNAL=1` refuses the
# corpus-wide freshness certificate so the per-file clock path is covered too.
# The daemon is held off (`GIST_NO_AUTOSERVE`/`GIST_NO_KEEP`) — the resident
# tier gets its own arm below, and letting it answer here would hide which tier
# a divergence came from.
chk() {
  local label="$1"
  shift
  (
    cd "${SUB}" || exit 1
    export GIST_NO_AUTOSERVE=1 GIST_NO_KEEP=1
    "${GIST}" "$@" --no-index < /dev/null > "${WORK}/.a" 2> /dev/null
    echo $? > "${WORK}/.ea"
    "${GIST}" "$@" < /dev/null > "${WORK}/.b" 2> /dev/null
    echo $? > "${WORK}/.eb"
    GIST_NO_JOURNAL=1 "${GIST}" "$@" < /dev/null > "${WORK}/.c" 2> /dev/null
    echo $? > "${WORK}/.ec"
  )
  local ea eb ec
  ea=$(cat "${WORK}/.ea") eb=$(cat "${WORK}/.eb") ec=$(cat "${WORK}/.ec")
  if [[ "${ea}" -ne "${eb}" || "${ea}" -ne "${ec}" ]]; then
    printf "  FAIL  %-24s exit differs (no-index=%s auto=%s uncertified=%s)\n" "${label}" "${ea}" "${eb}" "${ec}"
    fails=$((fails + 1))
    return
  fi
  local arm
  for arm in a b c; do LC_ALL=C sort "${WORK}/.${arm}" > "${WORK}/.${arm}.norm"; done
  if diff -q "${WORK}/.a.norm" "${WORK}/.b.norm" > /dev/null && diff -q "${WORK}/.b.norm" "${WORK}/.c.norm" > /dev/null; then
    printf "  ok    %-24s (%s lines)\n" "${label}" "$(wc -l < "${WORK}/.a" | tr -d ' ')"
  else
    printf "  FAIL  %-24s stdout differs:\n" "${label}"
    diff "${WORK}/.a.norm" "${WORK}/.b.norm" | head -12 | sed 's/^/        /'
    diff "${WORK}/.b.norm" "${WORK}/.c.norm" | head -12 | sed 's/^/  cert: /'
    fails=$((fails + 1))
  fi
}

# A claim about the whole run rather than about two arms of one: `<label>
# <expected> <actual>`.
same() {
  if [[ "$2" == "$3" ]]; then
    printf "  ok    %-24s (%s)\n" "$1" "$3"
  else
    printf "  FAIL  %-24s expected %s, got %s\n" "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

echo
echo "### queried from a subdirectory, riding the tree's artifacts ###"
chk "below-literal" needle_below
chk "below-lines" -n needle_below
chk "below-count" -c needle_below
chk "below-files" -l needle_below
chk "above-absent" needle_above
chk "above-absent-files" -l needle_above
chk "decoy-basename" -l notes
chk "regex" 'needle_\w+'
chk "caseless" -i NEEDLE_BELOW
chk "invert" -v needle_below
chk "files-without" --files-without-match needle_below
chk "context" -C1 needle_below
chk "path-scoped" needle_below deep
chk "no-match" zzz_nonexistent_qxv
# 2-byte literals extract no trigram, so the prefilter concedes and every
# unchanged file is served from the content shard — the tier where a dropped
# station hands back another file's BYTES rather than merely a bad skip.
chk "shard-2byte" -F '{}'
chk "shard-2byte-count" -cF '()'
chk "shard-2byte-lines" -nF '{}'

# Freshness in rebased coordinates: a subtree file that gained the needle after
# the build must still be read, and a subtree file whose bytes changed must not
# be served from its stale shard slice.
sleep 1
printf 'needle_below arrives post-index\n' >> "${SUB}/quiet.md"
printf 'late {} ()\n' >> "${SUB}/noise_3.md"
chk "freshness-gained" needle_below
chk "freshness-lines" -n needle_below
chk "shard-freshness" -cF '{}'

echo
echo "### building from a subdirectory ###"
# No explicit roots: a build is a statement about the TREE, so running it from
# inside one indexes the whole checkout and names every file from the root.
rm -rf "${TREE}/.gist"
(cd "${SUB}" && "${GIST}" index > "${WORK}/.idx" 2>&1)
same "sub-build-home" "1" "$([[ -d ${TREE}/.gist ]] && echo 1 || echo 0)"
same "sub-build-no-nested" "0" "$([[ -d ${SUB}/.gist ]] && echo 1 || echo 0)"
whole=$("${GIST}" --files 2> /dev/null | wc -l | tr -d ' ')
indexed=$("${GIST}" status 2> /dev/null | sed -n 's/.*files indexed *//p' | tr -d ' ')
same "sub-build-covers-tree" "${whole}" "${indexed}"
# And the root can then use it: a tree-root query after a subtree build must
# still agree with the live read, which is what the exit-2 "No such file or
# directory" failure mode looked like when the paths were written from the wrong
# place.
"${GIST}" needle_above --no-index 2> /dev/null | LC_ALL=C sort > "${WORK}/.ra"
"${GIST}" needle_above 2> /dev/null | LC_ALL=C sort > "${WORK}/.rb"
if diff -q "${WORK}/.ra" "${WORK}/.rb" > /dev/null; then
  printf "  ok    %-24s (%s lines)\n" "root-after-sub-build" "$(wc -l < "${WORK}/.ra" | tr -d ' ')"
else
  printf "  FAIL  %-24s stdout differs:\n" "root-after-sub-build"
  diff "${WORK}/.ra" "${WORK}/.rb" | head -8 | sed 's/^/        /'
  fails=$((fails + 1))
fi

# An EXPLICIT root is still a scope — it just gets named from the tree, so the
# same command means the same corpus wherever it was typed.
rm -rf "${TREE}/.gist"
(cd "${SUB}" && "${GIST}" index . > /dev/null 2>&1)
scoped=$("${GIST}" status 2> /dev/null | sed -n 's/.*roots *//p' | head -1 | tr -d ' ')
same "explicit-root-rebased" "services/ai" "${scoped}"

echo
echo "### a resident session belongs to where it stands ###"
# The socket lives in the one artifact home the whole tree shares, so a session
# that went resident in the subtree sits on the rendezvous a root query dials.
# Its answers are a walk from ITS directory, so it must decline the root's
# query and let it run cold — otherwise the root gets the subtree's rows, all
# of them real, most of the tree missing, and nothing in the output looks wrong.
rm -rf "${TREE}/.gist"
"${GIST}" index > /dev/null 2>&1
SOCK="${WORK}/station.sock"
(cd "${SUB}" && GIST_SESSION_SOCK="${SOCK}" GIST_NO_AUTOSERVE=1 "${GIST}" serve > "${WORK}/serve.log" 2>&1) &
serve_pid=$!
for _ in $(seq 1 100); do
  [[ -S "${SOCK}" ]] && break
  sleep 0.1
done
if [[ ! -S "${SOCK}" ]]; then
  echo "  FAIL  resident session never bound ${SOCK}"
  fails=$((fails + 1))
else
  # The ROUTING VERDICT is the assertion, not just the bytes. Comparing warm
  # output to cold output cannot fail if the daemon quietly declined for some
  # unrelated reason — the run would be cold ≡ cold, green and vacuous. So each
  # arm below states which tier must answer, and `GIST_TRACE=warm` reports which
  # one did.
  # `awk`, not `sed`: BSD sed has no `\|` alternation, and a helper that matches
  # nothing reports every routing as the empty string — which reads as a failure
  # here rather than a false pass, but only because the tier is asserted by name.
  route() { # <dir> <argv…> → the tier that answered
    local dir="$1"
    shift
    (cd "${dir}" && GIST_SESSION_SOCK="${SOCK}" GIST_NO_AUTOSERVE=1 GIST_NO_KEEP=1 \
      GIST_TRACE=warm "${GIST}" "$@" 2>&1 > /dev/null) |
      awk -F'[][]' '/^gist: \[(warm|cold)\]/ { v = $2 } END { print v }'
  }
  # Where the session stands, it answers — and if it does not, every other arm
  # here is meaningless, so this one fails loudly rather than passing quietly.
  same "sub-is-served-warm" "warm" "$(route "${SUB}" needle_below)"
  sub_warm=$(cd "${SUB}" && GIST_SESSION_SOCK="${SOCK}" GIST_NO_AUTOSERVE=1 "${GIST}" needle_below 2> /dev/null | LC_ALL=C sort)
  sub_cold=$(cd "${SUB}" && GIST_NO_AUTOSERVE=1 GIST_NO_KEEP=1 "${GIST}" needle_below --no-index 2> /dev/null | LC_ALL=C sort)
  same "sub-served-its-own" "${sub_cold}" "${sub_warm}"
  # And from anywhere else it must not. The tree root shares this rendezvous
  # now, so the decline has to come from the session's recorded STANDING; a
  # binding that only proved the tree would route this warm and hand back the
  # subtree's rows as the whole tree's answer.
  same "root-declines-to-cold" "cold" "$(route "${TREE}" needle_above)"
  root_warm=$(GIST_SESSION_SOCK="${SOCK}" GIST_NO_AUTOSERVE=1 "${GIST}" needle_above 2> /dev/null | LC_ALL=C sort)
  root_cold=$(GIST_NO_AUTOSERVE=1 GIST_NO_KEEP=1 "${GIST}" needle_above --no-index 2> /dev/null | LC_ALL=C sort)
  same "root-not-served-subtree" "${root_cold}" "${root_warm}"
fi
kill "${serve_pid}" 2> /dev/null
wait "${serve_pid}" 2> /dev/null

echo
if [[ "${fails}" -eq 0 ]]; then
  echo "PROVEN: a search from inside the tree rides the tree's index, shard, snapshot and session and still answers exactly what a full live read from that directory answers — the coordinate rebase changes speed, never results."
else
  echo "FAILED: ${fails} case(s) diverged — a tree-relative artifact is being read in working-directory coordinates, or the reverse. See the table above."
  exit 1
fi
