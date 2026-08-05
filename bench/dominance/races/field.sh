#!/usr/bin/env bash
# field.sh — WHO gist races and HOW each rival is invoked. SOURCED, never executed.
#
# The apparatus underneath — what the corpus is, how the indexed rivals get an
# index over it, and when a timing is allowed to count — is the vendored floor at
# `bench/apparatus/field.sh`, identical in all four packages. What lives HERE is
# the part that is gist's alone: the roster of tools it considers "the field",
# and the single fastest honest invocation of each for a given query class.
#
# Each tool is one of three kinds:
#
#   gist       — our kernel: build a trigram index once, then answer cold (fresh
#                process, candidate-only IO) or warm (resident RAM index).
#   indexed    — csearch (Google Code Search, Russ Cox — gist's direct trigram
#                ancestor) and zoekt (Sourcegraph's production indexed search).
#                Both build an index once, then each query is a fresh process
#                that loads the index + reads candidates — exactly gist's cold
#                model, which is why they belong in the cold/regex races.
#   unindexed  — rg, ugrep, ag, GNU grep (ggrep), git grep. No index: every
#                invocation re-walks the tree and re-scans, warm OR cold.
#
# FAIRNESS (stated, not hand-waved):
#   * Every tool is scoped to the same source ROOTS. gist/rg both disable the
#     VCS walker and consume the SAME explicit root `.gitignore`; this avoids
#     ripgrep's parallel multi-root parent-ignore re-anchoring producing a
#     nondeterministic oracle set. git-grep uses the tracked set natively; ag
#     receives the same root ignore. ugrep/GNU-grep have no per-file gitignore,
#     so they get the heavy dir-exclude set (`$XDIRS`) and conservatively scan
#     slightly more.
#   * csearch indexes gist's EXACT corpus file list (`paths.list`, the doc→path
#     table gist persists) → byte-for-byte the same files → result sets ≈ rg's
#     (the small delta is the few files csearch's own binary heuristic drops).
#     It is the faithful indexed twin.
#   * zoekt has no file-list input, so it indexes the ROOTS tree under the same
#     heavy ignore set; its corpus is a (documented) superset because it lacks
#     per-file gitignore and bundles ctags symbol indexing. Quoted-literal
#     counts still match rg on selective needles; treat it as a production
#     indexed *timing* reference, not a correctness oracle (rg + csearch are).

COMPETE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../apparatus/field.sh
source "${COMPETE_HERE}/../../apparatus/field.sh"

# compete_tools → echoes the ordered list of available tool ids (indexed first —
# they're the headline rivals — then unindexed). `gist` is printed by the scripts
# themselves, so it's omitted here. (The query class is currently the same field
# for literal + regex, so the arg is accepted but not branched on.)
compete_tools() {
  local t=()
  [[ "${HAVE_CSEARCH}" = 1 ]] && t+=(csearch)
  [[ "${HAVE_ZOEKT}" = 1 ]] && t+=(zoekt)
  [[ "${HAVE_RG}" = 1 ]] && t+=(rg)
  [[ "${HAVE_UGREP}" = 1 ]] && t+=(ugrep)
  [[ "${HAVE_AG}" = 1 ]] && t+=(ag)
  [[ "${HAVE_GGREP}" = 1 ]] && t+=(ggrep)
  [[ "${HAVE_GITGREP}" = 1 ]] && t+=(gitgrep)
  printf '%s\n' "${t[@]}" # one per line → callers `mapfile` from a plain assignment
}

compete_kind() { # echoes indexed|unindexed for a tool id
  case "$1" in
    csearch | zoekt) echo indexed ;;
    *) echo unindexed ;;
  esac
}

# ── per-tool command builders ────────────────────────────────────────────────
# compete_lit_cmd <tool> <needle>  → a shell command (list matching files) for a
#                                    fixed-string needle, each tool's fastest honest path.
# compete_rgx_cmd <tool> <pattern> → same for an RE2 regex at rg's DEFAULT
#                                    (Unicode) semantics — gist is Unicode-default
#                                    too now — or "" if the tool can't run it.
# ROOTS is expanded inline; needle/pattern are single-quoted (our slate has no
# single quotes). XDIRS is expanded to --exclude-dir flags for the no-gitignore tools.
_xdir_flags() {
  local f=""
  for d in "${XDIRS[@]}"; do f+=" --exclude-dir=${d}"; done
  echo "${f}"
}

compete_lit_cmd() {
  local tool="${1}" n="${2}" roots="${ROOTS[*]}" xd
  xd="$(_xdir_flags)"
  case "${tool}" in
    rg) echo "rg -F -l --sort none ${SCOPE} -- '${n}' ${roots}" ;;
    ugrep) echo "ugrep -rl -F${xd} -- '${n}' ${roots}" ;;
    ag) echo "ag -l -Q -s --path-to-ignore ${CORPUS}/.gitignore -- '${n}' ${roots}" ;;
    ggrep) echo "ggrep -rIlF${xd} -- '${n}' ${roots}" ;;
    gitgrep) echo "git -C ${CORPUS} grep -F -l -- '${n}' -- ${roots}" ;;
    csearch) echo "env CSEARCHINDEX='${CSEARCH_IDX}' csearch -l '\\Q${n}\\E'" ;;
    zoekt) echo "zoekt -index_dir '${ZOEKT_DIR}' -l '\"${n}\"'" ;;
    gist) echo "${GIST_BIN} '${n}' -F -l --sort none ${SCOPE} -- ${roots}" ;;
    *) echo "false" ;;
  esac
}

compete_rgx_cmd() {
  local tool="${1}" p="${2}" roots="${ROOTS[*]}" xd
  xd="$(_xdir_flags)"
  case "${tool}" in
    rg) echo "rg '${p}' -l --sort none ${SCOPE} -- ${roots}" ;;
    ugrep) echo "ugrep -rl -P${xd} -- '${p}' ${roots}" ;;
    ag) echo "ag -l -s --path-to-ignore ${CORPUS}/.gitignore -- '${p}' ${roots}" ;;
    ggrep) echo "ggrep -rIlP${xd} -- '${p}' ${roots}" ;;
    gitgrep) echo "git -C ${CORPUS} grep -lP -- '${p}' -- ${roots}" ;;
    csearch) echo "env CSEARCHINDEX='${CSEARCH_IDX}' csearch -l '${p}'" ;;
    zoekt) echo "zoekt -index_dir '${ZOEKT_DIR}' -l 'regex:${p}'" ;;
    gist) echo "${GIST_BIN} '${p}' -l --sort none ${SCOPE} -- ${roots}" ;;
    *) echo "false" ;;
  esac
}

# compete_count_cmd <tool> <needle> → a per-file COUNT command (grep `-c`) for a
# fixed-string needle. Distinct emit path from `-l`: `-l` short-circuits at the
# first hit per file, `-c` scans every candidate whole and tallies — the harder
# test of whether gist's index win survives when per-candidate work goes up.
# gist's `-c` is byte-parity with rg's (proven in the CLI matrix + flagbench), so
# the gist cell is oracle-gated against rg exactly like the `-l` lanes. Zoekt has
# no per-file grep `-c`, and csearch's `-c` is a total-match tally (not grep's
# per-line-per-file semantics), so both indexed rivals are absent BY CONSTRUCTION
# — the count field is the unindexed scanners (all grep-`-c` compatible) + gist.
compete_count_cmd() {
  local tool="${1}" n="${2}" roots="${ROOTS[*]}" xd
  xd="$(_xdir_flags)"
  case "${tool}" in
    rg) echo "rg -F -c --sort none ${SCOPE} -- '${n}' ${roots}" ;;
    ugrep) echo "ugrep -rc -F${xd} -- '${n}' ${roots}" ;;
    ag) echo "ag -c -Q -s --path-to-ignore ${CORPUS}/.gitignore -- '${n}' ${roots}" ;;
    ggrep) echo "ggrep -rIcF${xd} -- '${n}' ${roots}" ;;
    gitgrep) echo "git -C ${CORPUS} grep -c -F -- '${n}' -- ${roots}" ;;
    gist) echo "${GIST_BIN} '${n}' -F -c --sort none ${SCOPE} -- ${roots}" ;;
    *) echo "false" ;;
  esac
}

# compete_count_tools → the grep-`-c`-capable field (unindexed scanners), indexed
# rivals excluded by construction (see compete_count_cmd). `gist` is printed by
# the race script itself, so it's omitted here.
compete_count_tools() {
  local t=()
  [[ "${HAVE_RG}" = 1 ]] && t+=(rg)
  [[ "${HAVE_UGREP}" = 1 ]] && t+=(ugrep)
  [[ "${HAVE_AG}" = 1 ]] && t+=(ag)
  [[ "${HAVE_GGREP}" = 1 ]] && t+=(ggrep)
  [[ "${HAVE_GITGREP}" = 1 ]] && t+=(gitgrep)
  printf '%s\n' "${t[@]}"
}

# compete_pcre_cmd <tool> <pattern> → list-files command for a PCRE pattern
# (lookaround / backreferences — the class RE2 engines cannot express AT ALL).
# The indexed RE2 rivals csearch + zoekt are absent from this field by
# construction: their engines have neither lookaround nor backreferences, so gist
# is the ONLY indexed tool that can run this class. Every rival here re-walks and
# re-scans the whole tree; gist prefilters on the pattern's required literal (the
# same trigram index it uses for the linear engine) and PCRE2-JIT-matches only
# the surviving candidates — the structural win no scanner can answer. gist's
# `-P` defaults to PCRE2 UTF+UCP, exactly like rg `-P`, so their file sets match.
compete_pcre_cmd() {
  local tool="${1}" p="${2}" roots="${ROOTS[*]}" xd
  xd="$(_xdir_flags)"
  case "${tool}" in
    rg) echo "rg -P '${p}' -l --sort none ${SCOPE} -- ${roots}" ;;
    ugrep) echo "ugrep -rl -P${xd} -- '${p}' ${roots}" ;;
    ag) echo "ag -l -s --path-to-ignore ${CORPUS}/.gitignore -- '${p}' ${roots}" ;;
    ggrep) echo "ggrep -rIlP${xd} -- '${p}' ${roots}" ;;
    gitgrep) echo "git -C ${CORPUS} grep -lP -- '${p}' -- ${roots}" ;;
    gist) echo "${GIST_BIN} -P '${p}' -l --sort none ${SCOPE} -- ${roots}" ;;
    *) echo "false" ;;
  esac
}

# compete_pcre_tools → the PCRE-capable field, indexed RE2 rivals excluded
# (lookaround/backreferences are inexpressible in RE2). `gist` is printed by the
# race script itself, so it's omitted here.
compete_pcre_tools() {
  local t=()
  [[ "${HAVE_RG}" = 1 ]] && t+=(rg)
  [[ "${HAVE_UGREP}" = 1 ]] && t+=(ugrep)
  [[ "${HAVE_AG}" = 1 ]] && t+=(ag)
  [[ "${HAVE_GGREP}" = 1 ]] && t+=(ggrep)
  [[ "${HAVE_GITGREP}" = 1 ]] && t+=(gitgrep)
  printf '%s\n' "${t[@]}"
}
