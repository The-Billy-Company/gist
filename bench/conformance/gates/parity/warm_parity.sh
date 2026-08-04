#!/usr/bin/env bash
# gist WARM prefilter parity — the adverse guard for giving the resident session
# the cold tier's pruning stack (the conjunctive cover plan + the crest sieve).
#
# The warm tier used to ask the index exactly one question: the flat OR of the
# sound prefilter literals (`CompiledQuery.prefilter`). Cold has asked two
# stronger ones for a while — the CNF cover plan (`kernel/query/cover.zig`) and
# the crest sieve over per-doc ρ(d) (`kernel/math/crest.zig`) — so a
# literal-free class repetition like `[0-9a-f]{8}` had NO prunable trigram warm
# and the session scanned 100% of the corpus for it.
#
# Both new prunings are necessary conditions, which means strictly more elision —
# and a prefilter that elides one file it should have read is the worst defect a
# search tool can ship: silent, total, and indistinguishable from "no match".
# So this gate asserts the only property that matters, over the REAL corpus, on
# four arms per case:
#
#   warm   gist <case>                    (resident daemon, stack on)
#   base   gist <case> → base.sock        (a 2nd resident daemon, pre-wiring)
#   live   gist --no-index <case>         (no index at all — the semantic oracle)
#   rg     rg <case>                      (third-party oracle)
#
# All four must produce the same line multiset. `warm` vs `base` isolates the two
# new prunings on ONE binary (no build confound); `live` is the semantic ground
# truth, and the transitive proof that warm ≡ cold without both paths having to
# trust a shared index a coworker may rebuild mid-run; `rg` keeps gist's own
# paths from agreeing on a shared bug.
#
# The baseline is a SECOND DAEMON, not a client-side env var. Both stand-down
# knobs are read where the pruning is derived — `gather.winnowFor`, inside the
# resident session — so exporting them on a client that gets served warm changes
# nothing at all and the baseline arm would silently be a copy of the warm arm.
# Two sockets, two resident sessions, one binary.
#
# The case list is the axis list, not coverage theater — each exercises a
# distinct stand-down in `gather.winnowFor` / `gather.asked`:
#
#   -i            caseless stands the COVER down (the Unicode-fold bounds live
#                 once, in `caselessVariants`) but keeps the sieve
#   -F            a fixed string is not regex source: `cq.source` is null, so
#                 BOTH stand down and the literal path is untouched
#   -P            PCRE2 denotes the pattern under a foreign grammar: `cq.source`
#                 is null there too, and neither pruning may fire
#   -w            word only narrows the match set, so both stay fully sound
#   -v            invert walks every doc; `candidateIds` is a positive superset
#                 there, so a pruned doc must still report its non-matching lines
#   --no-unicode  the ASCII reading, where `\d` is 10 bytes and both fire
#   sieve-*       literal-free class repetitions — the class the trigram index
#                 concedes entirely and the sieve exists for
#   cover-*       patterns forcing several literals, where the plan beats the OR
#
# The corpus is REAL host source, copied into a throwaway tree and indexed
# there. The copy is the point: ~10 agents edit this branch concurrently, and a
# repo-wide arm takes long enough that two IDENTICAL runs already disagree.
# Freezing the bytes is what lets a difference between arms mean something.
#
# Usage: bench/conformance/gates/parity/warm_parity.sh
#        GIST_SIEVE_CORPUS="src bench" bench/conformance/gates/parity/warm_parity.sh
set -uo pipefail
# gist's ~25k-token agent-context output budget clips a repo-wide result; a
# clipped arm would read as lost lines rather than as a cap. Lift it (the hard
# OOM ceiling stays on) so all four arms are compared at full output.
export GIST_UNCAP=1

# ── the corpus this gate is TOLD, not one it assumes ─────────────────────────
# GIST_SIEVE_CORPUS — space-separated paths, relative to the corpus root
#   (`GIST_CORPUS_ROOT`, else this package), whose TRACKED files are frozen into
#   the throwaway tree. WHICH slices to freeze is a fact about the tree being
#   measured, and it used to be four literals naming slices of one particular
#   checkout. Anywhere else those pathspecs match nothing, so `git ls-files`
#   returned a fraction of what the gate thought it had asking — and a gate that
#   freezes a near-empty corpus still reports every arm as agreeing. It is a
#   declared input now, defaulting to slices this package actually ships so a
#   bare clone measures itself; nothing else about the gate's semantics moved.
#   `cover_parity.sh` reads the same knob, so the two sieve gates freeze the
#   same tree unless you deliberately tell them otherwise.
read -r -a SIEVE_CORPUS <<< "${GIST_SIEVE_CORPUS:-src bench}"

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../apparatus/roots.sh
source "${HERE}/../../../apparatus/roots.sh"
gist_resolve_roots "${HERE}" || exit 1
GIST="${KERNEL}/zig-out/bin/gist"

[[ -x "${GIST}" ]] || {
  echo "no gist binary at ${GIST} — run: cd ${KERNEL} && zig build -Doptimize=ReleaseFast"
  exit 1
}

# The corpus and the daemon's own files are SIBLINGS, never nested: `serve.log`
# grows a reconcile line mid-run, and a log inside the searched tree would make
# two arms of the same case disagree about a corpus that changed underneath them.
RUN="$(mktemp -d)"
WORK="${RUN}/corpus"
mkdir -p "${WORK}"
DAEMON_PIDS=()
DAEMON_LABELS=()
# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  for p in ${DAEMON_PIDS[@]+"${DAEMON_PIDS[@]}"}; do kill -9 "${p}" 2> /dev/null; done
  if [[ -n "${KEEP:-}" ]]; then
    echo "KEEP set — corpus, index, and daemon logs left at ${RUN}"
  else
    rm -rf "${RUN}"
  fi
}
trap cleanup EXIT

echo "freezing a real-source corpus under ${WORK}… (${SIEVE_CORPUS[*]})"
# Enumerate first and rsync second, rather than piping one into the other: the
# empty list is the failure this gate cannot afford to swallow, and inside a
# pipe it looks exactly like a successful copy of nothing.
MANIFEST="${RUN}/corpus.files"
(cd "${CORPUS}" && git ls-files -- "${SIEVE_CORPUS[@]}") > "${MANIFEST}"
[[ -s "${MANIFEST}" ]] || {
  echo "FAILED: GIST_SIEVE_CORPUS matched no tracked file under ${CORPUS}"
  echo "        asked for: ${SIEVE_CORPUS[*]}"
  echo "        Every arm agrees trivially on an empty corpus, so this gate"
  echo "        refuses rather than reporting a vacuous green. Name paths this"
  echo "        tree tracks, or point GIST_CORPUS_ROOT at the tree that has them."
  exit 1
}
(cd "${CORPUS}" && rsync -a --files-from="${MANIFEST}" . "${WORK}/") 2> /dev/null || {
  echo "  corpus copy failed"
  exit 1
}
cd "${WORK}" || exit 1
git init -q . 2> /dev/null || true # a repo so the rg-compat walk honors .gitignore
export GIST_DIR="${RUN}/gist"
corpus_files="$(find . -type f | wc -l | tr -d ' ')"
echo "indexing ${corpus_files} files…"
"${GIST}" index > /dev/null 2>&1 || {
  echo "  gist index failed"
  exit 1
}

# ── the resident session under test ──────────────────────────────────────────
#
# A PRIVATE socket, so this never collides with the rootless autoserve daemon a
# coworker's CLI spawned over the real tree — and every client below carries
# `GIST_NO_AUTOSERVE=1`, so a decline can never fork a second daemon onto it and
# silently re-scope the arm.
#
# ROOTLESS `serve`, not `serve .` — the production shape (`start the resident daemon from the sibling `gist` package` and
# the CLI's own auto-spawn both take no positional). A daemon rooted at `.`
# builds its mirror from that positional and then answers these ROOTLESS argvs
# with `./`-prefixed display paths, which is rg's own rendering for `gist pat .`
# but not for the argv the arms actually send. Every case would then "fail" on a
# two-byte prefix and say nothing about the prefilter stack.
SOCK="${RUN}/warm.sock"
BASE_SOCK="${RUN}/base.sock"

# `<label> <socket> [ENV=V …]` — bring one resident session up and wait for its
# bind. The stand-down knobs belong in the DAEMON's environment (see the header).
start_daemon() {
  local label="$1" sock="$2"
  shift 2
  local log="${RUN}/${label}.log" pid
  env "$@" GIST_SESSION_SOCK="${sock}" "${GIST}" serve > "${log}" 2>&1 &
  pid=$!
  DAEMON_PIDS+=("${pid}")
  DAEMON_LABELS+=("${label}")
  for _ in $(seq 1 60); do
    [[ -S "${sock}" ]] && break
    kill -0 "${pid}" 2> /dev/null || {
      echo "  ${label} daemon exited before binding — see ${log}"
      cat "${log}"
      exit 1
    }
    sleep 0.5
  done
  [[ -S "${sock}" ]] || {
    echo "  ${label} daemon never bound ${sock}"
    exit 1
  }
  local banner
  banner="$(grep -m1 -o 'warm on .*' "${log}")"
  printf '  %-10s %s\n' "${label}" "${banner}"
}

# `GIST_TRACE=index` is armed on the DAEMONS, not the clients: a lens mask is read
# once from the process that owns the pruning (`main.zig`), and the wire carries no
# lens field — a client exporting it gets nothing back for a warm query. The
# daemon's own trace then rides the v7 `diag` frame to each client's stderr, which
# is how the measurement below reads production's numbers instead of a harness's.
start_daemon warm "${SOCK}" GIST_TRACE=index
start_daemon pre-wiring "${BASE_SOCK}" GIST_TRACE=index GIST_NO_COVER=1 GIST_NO_CREST=1
export GIST_SESSION_SOCK="${SOCK}" GIST_NO_AUTOSERVE=1

# A warm arm is only evidence if it was actually SERVED warm. `GIST_TRACE=warm`
# prints the routing verdict, so a case whose argv the resident classifier
# declines is reported as cold rather than passing as a vacuous warm ≡ warm.
#
# The classifier's envelope is narrow on purpose and two exclusions shape every
# case below: `--no-heading` is not in it (a piped run gets that layout anyway,
# so the flag is redundant here and only costs the warm route), and a non-quiet
# `-c` is always cold (rg's count is per-file, the wire's is corpus-wide).
served_warm() { # <argv…> → 0 when the daemon answered
  GIST_TRACE=warm "${GIST}" "$@" 2>&1 > /dev/null | grep -q '^gist: \[warm\]'
}

# A dead daemon is INDISTINGUISHABLE from a healthy decline at the client: both
# spell themselves `[cold]`, and cold answers correctly, so every later case would
# keep passing while proving nothing about the warm tier. That is the exact shape
# of a vacuous green, so a death is a hard stop naming the case that caused it.
require_daemons() { # <case label>
  local i
  for i in "${!DAEMON_PIDS[@]}"; do
    kill -0 "${DAEMON_PIDS[i]}" 2> /dev/null && continue
    echo
    echo "FAILED: the ${DAEMON_LABELS[i]} daemon (pid ${DAEMON_PIDS[i]}) died during '$1'."
    echo "Every later case would silently route cold and pass without testing warm."
    echo "--- ${DAEMON_LABELS[i]}.log tail:"
    tail -20 "${RUN}/${DAEMON_LABELS[i]}.log"
    exit 1
  done
}

pass=0
fail=0
skip=0
cold_routed=0

# awk, not `grep -c ''`: grep exits 1 on empty input, so the usual `|| echo 0`
# guard prints a second zero and a legitimately-empty case reads as "0\n0".
nlines() { printf '%s' "$1" | awk 'END {print NR}'; }

# An arm disagreeing IS the finding, so name which arm, by how much, and show
# the first lines that diverge — a bare count would not say which way it broke.
mismatch() {
  local ours theirs
  ours="$(nlines "$3")"
  theirs="$(nlines "$4")"
  printf '  FAIL  %-22s warm ≠ %s  (%s vs %s lines)\n' "$1" "$2" "${ours}" "${theirs}"
  diff <(printf '%s' "$3") <(printf '%s' "$4") | head -5
  fail=$((fail + 1))
}

# One case = a label plus the argv every arm shares. `rg` is compared only when
# it is on PATH and the case is spelled in rg's own grammar (every case here is
# — gist is an rg-shaped CLI); `norg:` opts a case out.
check() {
  local label="$1"
  shift
  local norg=0
  if [[ "$1" == "norg:" ]]; then
    norg=1
    shift
  fi

  # Every arm is a pipe, so gist and rg both render the no-heading `path:line:`
  # frame by default — the flag itself is deliberately absent (see `served_warm`).
  local warm base live rgout
  warm="$("${GIST}" -n "$@" 2> /dev/null | LC_ALL=C sort)"
  require_daemons "${label}"
  base="$(GIST_SESSION_SOCK="${BASE_SOCK}" "${GIST}" -n "$@" 2> /dev/null | LC_ALL=C sort)"
  require_daemons "${label}"
  # The oracle must NOT touch the daemon: `--no-index` is ineligible warm, but
  # the socket env is exported, so unset it here to keep the arm honestly cold.
  live="$(env -u GIST_SESSION_SOCK "${GIST}" -n --no-index "$@" 2> /dev/null | LC_ALL=C sort)"

  if [[ "${warm}" != "${live}" ]]; then
    mismatch "${label}" live "${warm}" "${live}"
    return
  fi
  if [[ "${warm}" != "${base}" ]]; then
    mismatch "${label}" pre-wiring "${warm}" "${base}"
    return
  fi
  if [[ ${norg} -eq 0 ]] && command -v rg > /dev/null 2>&1; then
    rgout="$(rg -n "$@" 2> /dev/null | LC_ALL=C sort)"
    if [[ "${warm}" != "${rgout}" ]]; then
      mismatch "${label}" rg "${warm}" "${rgout}"
      return
    fi
  else
    skip=$((skip + 1))
  fi

  local route=warm count
  served_warm -n "$@" || {
    route=cold
    cold_routed=$((cold_routed + 1))
  }
  count="$(nlines "${warm}")"
  printf '  ok    %-22s %s lines (%s ≡ pre-wiring ≡ live ≡ rg)\n' \
    "${label}" "${count}" "${route}"
  pass=$((pass + 1))
}

echo
echo "### warm prefilter stack ≡ pre-wiring warm ≡ live ≡ rg ###"

# ── the stand-downs: a pruning that cannot be derived must cost speed, never a line
check caseless -i 'WalletService'
check caseless-regex -i 'wallet[a-z]+service'
check fixed -F 'pgxpool.New'
check fixed-caseless -F -i 'PGXPOOL.New'
check pcre2-lookahead -P 'func\s+(?!main)\w+\('
check pcre2-backref -P '(\w+)\s*=\s*\1'
check short-literal 'io'
check unprovable '.*'
check alternation-mixed 'panic|0x'

# ── the axes that could break the wiring ─────────────────────────────────────
check word-boundary -w 'WalletService'
check invert -v 'zzz_no_such_token'
check no-unicode --no-unicode '\d{4}-\d{2}-\d{2}'
check inline-ascii '(?-u)\d{4}-\d{2}-\d{2}'
check multi-pattern -e 'WalletService' -e 'pgxpool'
check max-count -m 2 'func'

# ── the crest sieve's own class: literal-free class repetitions ──────────────
check sieve-uuid '[0-9a-f]{8}-[0-9a-f]{4}'
check sieve-hex8 '[0-9a-f]{8}'
check sieve-digits '[0-9]{6,}'
check sieve-upper '[A-Z]{8,}'
check sieve-wordrun '\w{24,}'
check sieve-spacerun '[ ]{12,}'

# ── the cover plan's own class: several forced literals ──────────────────────
check cover-goerr 'if\s+err\s*!=\s*nil'
check cover-pubfn 'pub\s+fn\s+\w+\('
check cover-hexlit '0x[0-9a-fA-F]{6}'
check cover-url 'https?://[\w.]+'
check cover-adr 'ADR-\d{3}'
check cover-nilassign '\w+\s*:=\s*nil'

# ── the win, from the wired path itself ──────────────────────────────────────
#
# Parity alone can pass VACUOUSLY: a stack that never fires is trivially
# byte-identical to the one it never replaced. So read the tier and the admitted
# document count back out of the DAEMON's own `.index` trace and require each
# half to have actually narrowed something.
echo
echo "### what the resident session admits (production trace, not a harness) ###"
printf '  %-24s %9s %6s %8s %8s %8s %8s %6s\n' \
  pattern pre-wire tier by-cover by-sieve base-ms warm-ms gain
narrowed_cover=0
narrowed_sieve=0
# Both daemons run with the `.index` lens armed, so their per-query trace rides
# the `diag` frame to this client's stderr: these are the wired path's own
# numbers, read off production rather than re-derived by a harness. `tier=` is
# the index question that answered; the sieve line after it (when present) is the
# crest subtraction's own before/after. `-l` and not `-c`: a non-quiet count is
# always routed cold, so a `-c` probe would report cold's numbers here.
# stdout to the void, stderr to ours — the braces make the order unambiguous
# rather than relying on `2>&1 > /dev/null` reading right-to-left.
trace_of() { { "$@" > /dev/null; } 2>&1; }
tier_of() { trace_of "$@" | sed -n 's/.*warm tier=\([a-z]*\).*/\1/p' | head -1; }
cand_of() { trace_of "$@" | sed -n 's/.*warm tier=[a-z]*  *candidates=\([0-9]*\)\/.*/\1/p' | head -1; }
sieved_of() { trace_of "$@" | sed -n 's/.*warm sieve candidates=\([0-9]*\)\/.*/\1/p' | head -1; }

# Best-of-N wall clock in ms for one argv. The MINIMUM, not the mean: ~10 coworker
# agents share this laptop, so the mean measures the load average while the
# minimum measures gist. Both arms are the same resident-daemon round trip on one
# binary, so the client spawn and the socket handshake cancel out of the ratio.
bestms() {
  python3 - "$@" << 'PY'
import subprocess, sys, time
best = None
for _ in range(5):
    t = time.perf_counter()
    subprocess.run(sys.argv[1:], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    d = (time.perf_counter() - t) * 1000.0
    best = d if best is None else min(best, d)
print(f"{best:.1f}")
PY
}

gain_sum=0
gain_n=0
# `pre` → `warm_c` is the INDEX question changing (flat OR → cover plan); `warm_c`
# → `sv` is the sieve's own subtraction, downstream of whatever the index
# admitted. Attributing each column to the half that produced it is the point: a
# pattern like `[0-9a-f]{8}-[0-9a-f]{4}` gets a plan AND a sieve, and crediting
# its whole -95% to the sieve would overstate the half being introduced.
report() { # <pattern>
  local pat="$1" pre warm_c tier sv bms wms gain by_cover by_sieve
  pre=$(cand_of env GIST_SESSION_SOCK="${BASE_SOCK}" "${GIST}" -l "${pat}")
  warm_c=$(cand_of "${GIST}" -l "${pat}")
  tier=$(tier_of "${GIST}" -l "${pat}")
  sv=$(sieved_of "${GIST}" -l "${pat}")
  [[ -z "${pre}" || -z "${warm_c}" ]] && return
  bms=$(bestms env GIST_SESSION_SOCK="${BASE_SOCK}" "${GIST}" -l "${pat}")
  wms=$(bestms "${GIST}" -l "${pat}")
  gain=$(python3 -c "print(f'{${bms}/max(${wms},0.001):.2f}x')")

  by_cover="same"
  if [[ "${warm_c}" -lt "${pre}" ]]; then
    by_cover="$(((pre - warm_c) * 100 / pre))% off"
    narrowed_cover=$((narrowed_cover + 1))
  fi
  by_sieve="off"
  if [[ -n "${sv}" ]]; then
    by_sieve="same"
    if [[ "${sv}" -lt "${warm_c}" ]]; then
      by_sieve="$(((warm_c - sv) * 100 / warm_c))% off"
      narrowed_sieve=$((narrowed_sieve + 1))
    fi
  fi
  if [[ "${by_cover}" != "same" || "${by_sieve}" != "same" && "${by_sieve}" != "off" ]]; then
    gain_sum=$(python3 -c "import math;print(${gain_sum}+math.log(${bms}/max(${wms},0.001)))")
    gain_n=$((gain_n + 1))
  fi
  printf '  %-24s %9s %6s %8s %8s %8s %8s %6s\n' \
    "${pat:0:24}" "${pre}" "${tier}" "${by_cover}" "${by_sieve}" "${bms}" "${wms}" "${gain}"
}

# Cover's own class (several forced literals), then the sieve's (literal-free
# class repetition, which the trigram index concedes entirely).
for pat in 'if\s+err\s*!=\s*nil' 'pub\s+fn\s+\w+\(' '0x[0-9a-fA-F]{6}' \
  'https?://[\w.]+' '\w+\s*:=\s*nil' \
  '[0-9a-f]{8}-[0-9a-f]{4}' '[0-9a-f]{8}' '[0-9]{6,}' \
  '[A-Z]{8,}' '\w{24,}' '[ ]{12,}'; do report "${pat}"; done

echo
if [[ ${narrowed_cover} -eq 0 || ${narrowed_sieve} -eq 0 ]]; then
  echo "FAILED: the index question narrowed ${narrowed_cover} patterns and the sieve"
  echo "narrowed ${narrowed_sieve} — a half that never fires makes the parity above"
  echo "vacuous rather than proof, so this is a wiring failure and not a slow run."
  exit 1
fi
# Geomean over the narrowed patterns only: averaging in a pattern the stack
# provably cannot prune would report the share of the case list that happens to
# be prunable, not the speedup on the class it was built for.
geo=$(python3 -c "import math;print(f'{math.exp(${gain_sum}/${gain_n}):.2f}x')")
echo "geomean end-to-end on the ${gain_n} narrowed patterns: ${geo}"

if [[ ${fail} -eq 0 ]]; then
  echo "PROVEN: ${pass} cases — the resident session's cover plan + crest sieve emit a"
  echo "byte-identical line multiset to the pre-wiring warm path, to gist's own"
  echo "index-free read, and to ripgrep — while the cover plan narrowed the index answer"
  echo "on ${narrowed_cover} patterns and the sieve narrowed it further on ${narrowed_sieve}, worth ${geo} end-to-end."
  [[ ${skip} -gt 0 ]] && echo "(${skip} case(s) compared without the rg arm)"
  [[ ${cold_routed} -gt 0 ]] && echo "(${cold_routed} case(s) the resident classifier routes cold — proven there instead)"
  exit 0
fi
echo "FAILED: ${fail} of $((pass + fail)) cases — the warm prefilter stack changed an"
echo "ANSWER, not just a cost."
exit 1
