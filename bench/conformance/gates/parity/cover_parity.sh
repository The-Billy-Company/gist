#!/usr/bin/env bash
# gist conjunctive-cover parity — the adverse guard for wiring the CNF planner
# (the engine's `src/kernel/query/cover.zig`, in the sibling `irregex` package)
# onto the PRODUCTION query path.
#
# The planner is engine code, but this gate is a PRODUCT gate and lives here on
# purpose: it can only be run by the package that builds a `gist` binary, and
# `gist` depends on `irregex` rather than the other way round. Integration
# evidence belongs downstream of the thing it integrates.
#
# The cover is a strictly stronger necessary condition than the flat OR of
# extracted literals it replaces: where `trigramFilter` can state one
# disjunction, a plan states everything the pattern forces. Strictly stronger
# means strictly more elision — and a prefilter that elides one file it should
# have read is the worst defect a search tool can ship, silent and total.
#
# So this gate asserts the only property that matters, over the REAL corpus
# rather than a synthetic one, on FOUR arms per case:
#
#   cover    gist <case>                     (indexed, plan on — the wired path)
#   flat     GIST_NO_COVER=1 gist <case>     (indexed, the pre-wiring flat OR)
#   live     gist --no-index <case>          (no index at all — gist's own oracle)
#   rg       rg <case>                       (third-party oracle, where comparable)
#
# All four must produce the same line multiset. `cover` vs `flat` isolates the
# planner; `live` is the semantic ground truth (the index may only change
# speed); `rg` keeps gist's own two paths from agreeing on a shared bug.
#
# The case list is chosen for the axes that can actually break the wiring, not
# for coverage theater — each one exercises a distinct branch of
# `gate.winnow` / `elide.askIndex`:
#
#   -i          caseless stands the cover down (`caselessFilter` keeps the
#               Unicode-fold bounds); proves the stand-down is not a silent drop
#   -U          multiline reaches the plan through `arm.linearOptions`
#   -F          fixed strings are not a regex and must stay on the literal path
#   -e A -e B   multi-pattern folds to `(?:a)|(?:b)`; the plan must be the UNION
#   -P          PCRE2 gets no plan (dual-grammar hazard) and must not lose lines
#   --no-unicode  the ASCII reading, where `\d` is 10 bytes and the cover fires
#   winners     one pattern from each class the cover measurably improves
#
# The corpus is REAL host source (thousands of tracked Go/Zig/TS/Markdown
# files), copied into a throwaway tree and indexed there. The copy is the point:
# ~10 agents edit this branch concurrently, and a repo-wide arm takes long enough
# that two IDENTICAL runs already disagree — measured, not assumed. Freezing the
# bytes is what lets a difference between arms mean something.
#
# Usage: bench/conformance/gates/parity/cover_parity.sh
#        GIST_SIEVE_CORPUS="src bench" bench/conformance/gates/parity/cover_parity.sh
#
# GIST_SIEVE_CORPUS — space-separated paths, relative to the corpus root, whose
#   tracked files are frozen. Declared rather than assumed, and the SAME knob
#   `warm_parity.sh` reads (documented at length there), so the two sieve gates
#   freeze the same tree unless you deliberately tell them otherwise. This one
#   keeps its own fallback: a path the tree does not have is dropped, and a list
#   that drops to nothing degrades to `src .` rather than refusing.
set -uo pipefail
# gist's ~25k-token agent-context output budget clips a repo-wide result; a
# clipped arm would read as lost lines rather than as a cap. Lift it (the hard
# OOM ceiling stays on) so all four arms are compared at full output.
export GIST_UNCAP=1

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../apparatus/roots.sh
source "${HERE}/../../../apparatus/roots.sh"
gist_resolve_roots "${HERE}" || exit 1
GIST="${KERNEL}/zig-out/bin/gist"

[[ -x "${GIST}" ]] || {
  echo "no gist binary at ${GIST} — run: cd ${KERNEL} && zig build -Doptimize=ReleaseFast"
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
echo "freezing a real-source corpus under ${WORK}…"
# Keep the slices the corpus root actually has; else fall back to the whole tree.
read -r -a _cover_want <<< "${GIST_SIEVE_CORPUS:-src bench}"
_cover_paths=()
for _p in "${_cover_want[@]}"; do
  [[ -e "${CORPUS}/${_p}" ]] && _cover_paths+=("${_p}")
done
[[ ${#_cover_paths[@]} -gt 0 ]] || _cover_paths=(src .)
(
  cd "${CORPUS}" && git ls-files "${_cover_paths[@]}"
) | (cd "${CORPUS}" && rsync -a --files-from=- . "${WORK}/") 2> /dev/null || {
  echo "  corpus copy failed"
  exit 1
}
cd "${WORK}" || exit 1
git init -q . 2> /dev/null || true # a repo so the rg-compat walk honors .gitignore
export GIST_DIR="${WORK}/.gist"
echo "indexing $(find . -type f | wc -l | tr -d ' ') files…"
"${GIST}" index > /dev/null 2>&1 || {
  echo "  gist index failed"
  exit 1
}

pass=0
fail=0
skip=0

# awk, not `grep -c ''`: grep exits 1 on empty input, so the usual `|| echo 0`
# guard prints a second zero and a legitimately-empty case reads as "0\n0".
nlines() { printf '%s' "$1" | awk 'END {print NR}'; }

# An arm disagreeing IS the finding, so name which arm, by how much, and show
# the first lines that diverge — a bare count would not say which way it broke.
mismatch() {
  printf '  FAIL  %-22s cover ≠ %s  (%s vs %s lines)\n' \
    "$1" "$2" "$(nlines "$3")" "$(nlines "$4")"
  diff <(printf '%s' "$3") <(printf '%s' "$4") | head -5
  fail=$((fail + 1))
}

# One case = a label plus the argv every arm shares. `rg` is compared only when
# it is on PATH and the case is spelled in rg's own grammar (every case here is
# — gist is an rg-shaped CLI), and a case may opt out of the rg arm with
# `norg:` when the flag has no rg equivalent.
check() {
  local label="$1"
  shift
  local norg=0
  if [[ "$1" == "norg:" ]]; then
    norg=1
    shift
  fi

  local cover flat live rgout
  cover="$("${GIST}" -n --no-heading "$@" 2> /dev/null | LC_ALL=C sort)"
  flat="$(GIST_NO_COVER=1 "${GIST}" -n --no-heading "$@" 2> /dev/null | LC_ALL=C sort)"
  live="$("${GIST}" -n --no-heading --no-index "$@" 2> /dev/null | LC_ALL=C sort)"

  if [[ "${cover}" != "${live}" ]]; then
    mismatch "${label}" live "${cover}" "${live}"
    return
  fi
  if [[ "${cover}" != "${flat}" ]]; then
    mismatch "${label}" flat-OR "${cover}" "${flat}"
    return
  fi

  if [[ ${norg} -eq 0 ]] && command -v rg > /dev/null 2>&1; then
    rgout="$(rg -n --no-heading "$@" 2> /dev/null | LC_ALL=C sort)"
    if [[ "${cover}" != "${rgout}" ]]; then
      mismatch "${label}" rg "${cover}" "${rgout}"
      return
    fi
  else
    skip=$((skip + 1))
  fi

  printf '  ok    %-22s %s lines (cover ≡ flat ≡ live ≡ rg)\n' "${label}" "$(nlines "${cover}")"
  pass=$((pass + 1))
}

echo
echo "### conjunctive cover ≡ flat-OR ≡ live ≡ rg ###"

# ── the syntax axes that could break the wiring ──────────────────────────────
check caseless -i 'WalletService'
check caseless-regex -i 'wallet[a-z]+service'
check multiline -U 'func\s+\w+\([^)]*\)\s*\{'
check fixed -F 'pgxpool.New'
check multi-pattern -e 'WalletService' -e 'pgxpool'
check multi-pattern-3 -e 'ADR-3[0-9]{2}' -e 'pgxpool' -e 'billog'
check pcre2-lookahead -P 'func\s+(?!main)\w+\('
check pcre2-backref -P '(\w+)\s*=\s*\1'
check word-boundary -w 'WalletService'
check no-unicode --no-unicode '\d{4}-\d{2}-\d{2}'
check inline-ascii '(?-u)\d{4}-\d{2}-\d{2}'

# ── one pattern from each class the cover measurably improves ────────────────
check win-goerr 'if\s+err\s*!=\s*nil'
check win-pubfn 'pub\s+fn\s+\w+\('
check win-hexlit '0x[0-9a-fA-F]{6}'
check win-url 'https?://[\w.]+'
check win-adr 'ADR-\d{3}'
check win-nilassign '\w+\s*:=\s*nil'
check win-wraperr '\.(Unwrap|Wrap)Err\('

# ── the declines: a plan that cannot be built must cost pruning, never a line ─
check short-literal 'io'
check alternation-mixed 'panic|0x'
check unprovable '.*'

# ── the win, from the wired path itself ──────────────────────────────────────
#
# Parity alone can pass VACUOUSLY: a cover that never fires is trivially
# byte-identical to the flat OR it never replaced. So read the tier and the
# admitted-document count back out of production (`elide.askIndex`'s `.index`
# trace) and require the plan to have actually answered, with a strictly smaller
# candidate set than the pre-wiring path on at least one class.
echo
echo "### what the wired path admits (production trace, not a harness) ###"
printf '  %-24s %10s %10s %9s\n' pattern flat cover delta
narrowed=0
tier_of() { "$@" 2>&1 > /dev/null | sed -n 's/.*tier=\([a-z]*\).*/\1/p' | head -1; }
cand_of() { "$@" 2>&1 > /dev/null | sed -n 's/.*candidates=\([0-9]*\)\/.*/\1/p' | head -1; }
for pat in 'if\s+err\s*!=\s*nil' 'pub\s+fn\s+\w+\(' '0x[0-9a-fA-F]{6}' \
  'https?://[\w.]+' '\w+\s*:=\s*nil' '(?-u)\d{4}-\d{2}-\d{2}'; do
  c=$(cand_of env GIST_TRACE=index "${GIST}" -c "${pat}" .)
  f=$(cand_of env GIST_NO_COVER=1 GIST_TRACE=index "${GIST}" -c "${pat}" .)
  t=$(tier_of env GIST_TRACE=index "${GIST}" -c "${pat}" .)
  [[ -z "${c}" || -z "${f}" ]] && continue
  if [[ "${t}" == "cover" && "${c}" -lt "${f}" ]]; then
    narrowed=$((narrowed + 1))
    printf '  %-24s %10s %10s %8s%%\n' "${pat:0:24}" "${f}" "${c}" \
      "-$(((f - c) * 100 / f))"
  else
    printf '  %-24s %10s %10s %9s\n' "${pat:0:24}" "${f}" "${c}" "tier=${t}"
  fi
done
if [[ ${narrowed} -eq 0 ]]; then
  echo
  echo "FAILED: the cover never answered — parity here is vacuous, not proof."
  exit 1
fi

echo
if [[ ${fail} -eq 0 ]]; then
  echo "PROVEN: ${pass} cases — the conjunctive cover emits a byte-identical line"
  echo "multiset to the flat-OR prefilter, to gist's own index-free read, and to"
  echo "ripgrep, while admitting a strictly smaller candidate set on ${narrowed} classes."
  [[ ${skip} -gt 0 ]] && echo "(${skip} case(s) compared without the rg arm)"
  exit 0
fi
echo "FAILED: ${fail} of $((pass + fail)) cases — the cover changed an ANSWER, not just a cost."
exit 1
