#!/usr/bin/env bash
# _compete.sh — shared competitor registry for the gist race scripts. SOURCED,
# never executed.
#
# The point of this file is a single, honest definition of "the field": which
# code-search tools gist races, how each is invoked on its fastest honest path,
# and how the two *indexed* rivals (csearch, zoekt) get an index built over the
# SAME corpus gist sees — so an indexed-vs-indexed race is apples-to-apples, not
# a strawman. Each tool is one of three kinds:
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
#
# Tool columns auto-skip when a binary is not installed. Install hints:
#   ugrep:   brew install ugrep
#   ggrep:   brew install grep          (GNU grep as `ggrep` on macOS)
#   csearch: go install github.com/google/codesearch/cmd/{cindex,csearch}@latest
#   zoekt:   go install github.com/sourcegraph/zoekt/cmd/{zoekt-index,zoekt}@latest

# ── locations ────────────────────────────────────────────────────────────────
COMPETE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="$(cd "${COMPETE_HERE}/../.." && pwd)" # races/ → bench/ → gist root
REPO="$(cd "${KERNEL}/../../.." && pwd)"
OUT="${REPO}/.local/gist-verify"          # gist's persisted index + paths.list live here
COMPETE_DIR="${REPO}/.local/gist-compete" # competitor indices live here
GIST_BIN="${REPO}/.local/gist-bin"
CSEARCH_IDX="${COMPETE_DIR}/csearch.idx"
ZOEKT_DIR="${COMPETE_DIR}/zoekt"
PATHS_LIST="${OUT}/paths.list"
ROOTS=(services libs clients contracts scripts quality)

# Heavy build/cache dirs that have no per-file gitignore equivalent for ugrep /
# GNU grep / zoekt. Mirrors gist's own ignored-subtree set + the rule-of-five
# ignored dirs, so every tool is scoped to roughly the same logical corpus.
XDIRS=(node_modules target .venv venv __pycache__ .zig-cache zig-out dist
  dist-types build .build out .next coverage .turbo .mypy_cache .ruff_cache
  .pytest_cache Pods DerivedData .swiftpm vendor .local .cache .parcel-cache
  storybook-static xcuserdata graphify-out .pnpm-store .git .hg .svn)

# ── availability ──────────────────────────────────────────────────────────────
have() { command -v "$1" > /dev/null 2>&1; }
HAVE_RG=0
have rg && HAVE_RG=1
HAVE_UGREP=0
have ugrep && HAVE_UGREP=1
HAVE_AG=0
have ag && HAVE_AG=1
HAVE_GGREP=0
have ggrep && HAVE_GGREP=1
HAVE_GITGREP=0
have git && HAVE_GITGREP=1
HAVE_CSEARCH=0
have csearch && have cindex && HAVE_CSEARCH=1
HAVE_ZOEKT=0
have zoekt && have zoekt-index && HAVE_ZOEKT=1

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

# ── gist binary install ───────────────────────────────────────────────────────
# compete_install_gist_bin → copy the deterministic installed `gist` CLI (the
# `index`/`status`/`rg` verbs + bare shorthand) from `zig-out/bin`. Never select
# a hash-named cache artifact by mtime: an older intermediate build can have a
# newer timestamp and silently invalidate every gate/certificate.
#
# The ad-hoc re-sign is load-bearing on macOS: `cp`-ing a Mach-O strips its
# ad-hoc code signature, and syspolicyd then SIGKILLs ("Killed: 9") the first
# exec(s) of the copy while it re-evaluates — which silently breaks a gate that
# runs the binary once (a later re-exec in the same script appears to "work",
# masking it). `codesign --sign -` re-stamps the copy so it runs on first exec.
# No-op where codesign is absent (Linux). Returns 1 if no binary was found.
compete_install_gist_bin() {
  local exe_src="${KERNEL}/zig-out/bin/gist"
  [[ -x "${exe_src}" ]] || {
    echo "  no installed gist CLI at ${exe_src} — run zig build first"
    return 1
  }
  mkdir -p "$(dirname "${GIST_BIN}")"
  cp "${exe_src}" "${GIST_BIN}"
  command -v codesign > /dev/null 2>&1 && codesign --force --sign - "${GIST_BIN}" > /dev/null 2>&1
  return 0
}

compete_build_gist_index() {
  (cd "${KERNEL}" && zig build -Doptimize=ReleaseFast) || return 1
  compete_install_gist_bin || return 1
  (cd "${REPO}" && "${GIST_BIN}" index) || return 1
}

# ── index construction (once per run) ────────────────────────────────────────
# Build the csearch index over gist's EXACT corpus (the persisted paths.list),
# so the two trigram indexes cover byte-identical files. Prints build seconds +
# index size. Requires gist's index already persisted (paths.list present).
compete_build_csearch() {
  [[ "${HAVE_CSEARCH}" = 1 ]] || return 0
  [[ -f "${PATHS_LIST}" ]] || {
    echo "  csearch: no ${PATHS_LIST} (run gist index first)"
    HAVE_CSEARCH=0
    return 0
  }
  mkdir -p "${COMPETE_DIR}"
  rm -f "${CSEARCH_IDX}"
  local t0 t1 secs bytes human
  t0="$(python3 -c 'import time;print(time.time())')"
  (cd "${REPO}" && xargs -0 -n 400 env CSEARCHINDEX="${CSEARCH_IDX}" cindex < "${PATHS_LIST}" > /dev/null 2>&1)
  t1="$(python3 -c 'import time;print(time.time())')"
  secs="$(python3 -c "print('%.1f'%(${t1}-${t0}))")"
  bytes="$(stat -f%z "${CSEARCH_IDX}" 2> /dev/null || echo 0)"
  human="$(_compete_humansize "${bytes}")"
  printf "  csearch index: %ss · %s\n" "${secs}" "${human}"
}

# Build the zoekt index over the ROOTS tree under the heavy ignore set.
compete_build_zoekt() {
  [[ "${HAVE_ZOEKT}" = 1 ]] || return 0
  mkdir -p "${COMPETE_DIR}"
  rm -rf "${ZOEKT_DIR}"
  mkdir -p "${ZOEKT_DIR}"
  local ign t0 t1 secs du_out kb human shard_arr
  ign="$(
    IFS=,
    echo "${XDIRS[*]}"
  )"
  t0="$(python3 -c 'import time;print(time.time())')"
  (cd "${REPO}" && zoekt-index -index "${ZOEKT_DIR}" -ignore_dirs "${ign}" "${ROOTS[@]}" > /dev/null 2>&1)
  t1="$(python3 -c 'import time;print(time.time())')"
  secs="$(python3 -c "print('%.1f'%(${t1}-${t0}))")"
  du_out="$(du -sk "${ZOEKT_DIR}")"
  kb="${du_out%%[!0-9]*}" # leading kb field, no pipe
  human="$(_compete_humansize "$((kb * 1024))")"
  shard_arr=("${ZOEKT_DIR}"/*.zoekt) # glob → count, no `ls`
  printf "  zoekt index:   %ss · %s · %s shards\n" "${secs}" "${human}" "${#shard_arr[@]}"
}

_compete_humansize() { python3 -c "b=${1:-0};print(('%.0f B'%b) if b<1024 else ('%.1f KiB'%(b/1024)) if b<1048576 else ('%.1f MiB'%(b/1048576)))"; }

# ── per-tool command builders ────────────────────────────────────────────────
# compete_lit_cmd <tool> <needle>  → a shell command (list matching files) for a
#                                    fixed-string needle, each tool's fastest honest path.
# compete_rgx_cmd <tool> <pattern> → same for an RE2/(?-u)-byte regex, or "" if
#                                    the tool can't run that class.
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
    rg) echo "rg -F -l --sort none --no-ignore-vcs --ignore-file '${REPO}/.gitignore' -- '${n}' ${roots}" ;;
    ugrep) echo "ugrep -rl -F${xd} -- '${n}' ${roots}" ;;
    ag) echo "ag -l -Q -s --path-to-ignore ${REPO}/.gitignore -- '${n}' ${roots}" ;;
    ggrep) echo "ggrep -rIlF${xd} -- '${n}' ${roots}" ;;
    gitgrep) echo "git -C ${REPO} grep -F -l -- '${n}' -- ${roots}" ;;
    csearch) echo "env CSEARCHINDEX='${CSEARCH_IDX}' csearch -l '\\Q${n}\\E'" ;;
    zoekt) echo "zoekt -index_dir '${ZOEKT_DIR}' -l '\"${n}\"'" ;;
    gist) echo "${GIST_BIN} '${n}' -F -l --sort none --no-ignore-vcs --ignore-file '${REPO}/.gitignore' -- ${roots}" ;;
    *) echo "false" ;;
  esac
}

compete_rgx_cmd() {
  local tool="${1}" p="${2}" roots="${ROOTS[*]}" xd
  xd="$(_xdir_flags)"
  case "${tool}" in
    rg) echo "rg '(?-u)${p}' -l --sort none --no-ignore-vcs --ignore-file '${REPO}/.gitignore' -- ${roots}" ;;
    ugrep) echo "ugrep -rl -P${xd} -- '${p}' ${roots}" ;;
    ag) echo "ag -l -s --path-to-ignore ${REPO}/.gitignore -- '${p}' ${roots}" ;;
    ggrep) echo "ggrep -rIlP${xd} -- '${p}' ${roots}" ;;
    gitgrep) echo "git -C ${REPO} grep -lP -- '${p}' -- ${roots}" ;;
    csearch) echo "env CSEARCHINDEX='${CSEARCH_IDX}' csearch -l '${p}'" ;;
    zoekt) echo "zoekt -index_dir '${ZOEKT_DIR}' -l 'regex:${p}'" ;;
    gist) echo "${GIST_BIN} '${p}' -l --sort none --no-ignore-vcs --ignore-file '${REPO}/.gitignore' -- ${roots}" ;;
    *) echo "false" ;;
  esac
}

# ── semantic + timing helpers (shared by every race script) ──────────────────
need_hyperfine() { have hyperfine || {
  echo "need hyperfine (brew install hyperfine)"
  exit 1
}; }

# Capture a complete list-files result as an order-insensitive exact set. Exit 1
# is rg's valid no-match result; >=2 is always a hard benchmark failure.
compete_capture_set() { # <cmd> <sorted-output> <label>
  local cmd="$1" out="$2" label="${3:-command}" rc
  local raw="${out}.raw" err="${out}.err"
  bash -c "${cmd}" > "${raw}" 2> "${err}"
  rc=$?
  if [[ "${rc}" -ge 2 ]]; then
    echo "  HARD ERROR (exit ${rc}) ${label}: ${cmd}" >&2
    rm -f "${raw}" "${err}"
    return 1
  fi
  LC_ALL=C sort -u "${raw}" > "${out}" || {
    rm -f "${raw}" "${err}"
    return 1
  }
  rm -f "${raw}" "${err}"
}

compete_precheck_status() { # <cmd> <label>
  local cmd="$1" label="${2:-command}" rc
  bash -c "${cmd}" > /dev/null 2>&1
  rc=$?
  if [[ "${rc}" -ge 2 ]]; then
    echo "  HARD ERROR (exit ${rc}) ${label}: ${cmd}" >&2
    return 1
  fi
}

# The candidate and official-rg oracle must emit the same complete file set
# before a gist cell may be timed. This is intentionally independent of order.
compete_precheck_equivalent() { # <candidate-cmd> <rg-cmd> <label>
  local candidate="$1" oracle="$2" label="${3:-gist cell}" tmp
  tmp="$(mktemp -d)"
  if ! compete_capture_set "${candidate}" "${tmp}/candidate" "${label}/gist" \
    || ! compete_capture_set "${oracle}" "${tmp}/oracle" "${label}/rg"; then
    rm -rf "${tmp}"
    return 1
  fi
  if ! cmp -s "${tmp}/candidate" "${tmp}/oracle"; then
    echo "  SEMANTIC MISMATCH ${label}: gist file set != rg" >&2
    diff -u "${tmp}/oracle" "${tmp}/candidate" > "${tmp}/diff" || true
    awk 'NR <= 12 { print "    " $0 }' "${tmp}/diff" >&2
    rm -rf "${tmp}"
    return 1
  fi
  rm -rf "${tmp}"
}

# Hyperfine's own pipe sink forces complete output without a shell pipeline, so
# the producer's status stays authoritative. Only rg's no-match exit 1 is
# ignored; any >=2 during a measured iteration aborts the cell.
compete_hyperfine() {
  hyperfine --output=pipe --ignore-failure=1 "$@"
}

_hf_value() { # <mean|min> <warmup> <runs> <cmd> [official-rg-oracle]
  local stat="$1" warmup="$2" runs="$3" cmd="$4" oracle="${5:-}" js rc
  if [[ -n "${oracle}" ]]; then
    compete_precheck_equivalent "${cmd}" "${oracle}" "${stat} benchmark" || return 1
  else
    compete_precheck_status "${cmd}" "${stat} benchmark" || return 1
  fi
  js="$(mktemp)"
  if ! compete_hyperfine --warmup "${warmup}" --runs "${runs}" \
    --export-json "${js}" "${cmd}" > /dev/null 2>&1; then
    echo "  TIMED COMMAND FAILED: ${cmd}" >&2
    rm -f "${js}"
    return 1
  fi
  python3 - "${js}" "${stat}" << 'PY'
import json
import sys

result = json.load(open(sys.argv[1]))["results"][0]
value = result["mean"] if sys.argv[2] == "mean" else min(result["times"])
print(f"{value * 1000:.1f}")
PY
  rc=$?
  rm -f "${js}"
  return "${rc}"
}

hf_mean() { _hf_value mean "$@"; }
hf_min() { _hf_value min "$@"; }

ratio() {
  [[ "$1" = "?" || "$2" = "?" ]] && {
    echo "?"
    return
  }
  python3 -c "print('%.1fx'%(${1}/${2}))" 2> /dev/null || echo "?"
}
geomean() { python3 -c "import sys,math;v=[float(x) for x in sys.argv[1:] if x not in ('?','')];print('%.1f'%math.exp(sum(map(math.log,v))/len(v)) if v else 0)" "$@"; }
