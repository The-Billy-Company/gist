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

# gist's default output budget (the ~25k-token agent-context guard) would clip a
# repo-wide result and perturb the ripgrep oracle; every race/gate here diffs or
# times gist against rg's uncapped output, so lift the soft cap process-wide. The
# hard OOM ceiling stays on. (corpus.zig::initOutputBudget honors this env.)
export GIST_UNCAP=1

# ── locations ────────────────────────────────────────────────────────────────
COMPETE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# races/ → dominance/ → bench/ → package root (this repo).
REPO="$(cd "${COMPETE_HERE}/../../.." && pwd)"
# Compat alias: lanes historically called the package root KERNEL (nested under
# a monorepo). Both names now mean this checkout.
KERNEL="${REPO}"
# Corpus base: the tree every tool actually SEARCHES. Defaults to this package,
# but the evaluator can point it at an immutable copy-on-write snapshot
# (GIST_CORPUS_ROOT) so a live coworking tree can't churn under a parity/timing
# capture. Only the search base moves — the built binary, persisted index, and
# competitor indices stay under REPO.
CORPUS="${GIST_CORPUS_ROOT:-${REPO}}"
OUT="${GIST_DIR:-${REPO}/.local/gist-verify}" # gist's persisted index + paths.list live here (GIST_DIR-relocatable)
COMPETE_DIR="${REPO}/.local/gist-compete"     # competitor indices live here
GIST_BIN="${REPO}/.local/gist-bin"
RELATE_BIN="${REPO}/.local/relate-bin" # the compression-search face (similar/dups/patterns)
CSEARCH_IDX="${COMPETE_DIR}/csearch.idx"
ZOEKT_DIR="${COMPETE_DIR}/zoekt"
PATHS_LIST="${OUT}/paths.list"
# Corpus scope: $GIST_ROOTS override (`:`/`,`/space separated), else the
# historical published-corpus roots when they all exist here (the source
# monorepo), else the whole tree — mirrors `corpus.resolveRoots`.
if [[ -n "${GIST_ROOTS:-}" ]]; then
  read -ra ROOTS <<< "${GIST_ROOTS//[:,]/ }"
else
  ROOTS=(services libs clients contracts scripts quality)
  for r in "${ROOTS[@]}"; do [[ -d "${CORPUS}/${r}" ]] || {
    ROOTS=(.)
    break
  }; done
fi

# Heavy build/cache dirs that have no per-file gitignore equivalent for ugrep /
# GNU grep / zoekt. Mirrors gist's own ignored-subtree set + the rule-of-five
# ignored dirs, so every tool is scoped to roughly the same logical corpus.
XDIRS=(node_modules target .venv venv __pycache__ .zig-cache zig-out dist
  dist-types build .build out .next coverage .turbo .mypy_cache .ruff_cache
  .pytest_cache Pods DerivedData .swiftpm vendor .local .cache .parcel-cache
  storybook-static xcuserdata graphify-out .pnpm-store .git .hg .svn)

# gist/rg run under `--no-ignore-vcs` for a deterministic multi-root oracle set
# (see FAIRNESS above), but that also discards every NESTED `.gitignore` — which
# silently re-admits ~2.5k build artifacts the root `.gitignore` never names:
# Elixir `_build`/`deps`/`cover` beam output and Electron `out/`. gist's own
# indexer prunes those, so they are absent from `paths.list` and therefore from
# csearch's corpus — racing gist/rg over a strict SUPERSET of the indexed
# rivals' corpus is not the like-for-like this file claims (measured: +2,488
# files, all build output, 1.47x on gist's `literal-rare` cell). Re-apply them
# as the glob equivalent of what XDIRS already gives the other no-gitignore
# tools. NOT the whole of XDIRS: a tracked `vendor/` tree can hold source the
# index admits, so a bare exclude would push gist BELOW the indexed corpus.
# Mix output is anchored per `mix.exs` root for the same reason — `deps`/`doc`
# are too generic to exclude by name.
_scope_globs() {
  local g="--glob=!out/" m
  while IFS= read -r m; do
    g+=" --glob=!${m}/_build/ --glob=!${m}/deps/ --glob=!${m}/cover/ --glob=!${m}/doc/"
  done < <(
    # shellcheck disable=SC2312 # discovery loop over optional mix.exs roots — an empty result (no Elixir projects) is a valid, non-error outcome
    cd "${CORPUS}" && find "${ROOTS[@]}" -maxdepth 3 -name mix.exs -print 2> /dev/null | while IFS= read -r f; do dirname "${f}"; done
  )
  echo "${g}"
}
# The ignore scope gist and rg SHARE, resolved once: identical flags on both
# sides keep the rg-oracle gate honest (verified byte-identical `--files` sets).
SCOPE="--no-ignore-vcs --ignore-file '${CORPUS}/.gitignore' $(_scope_globs)"

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
# git grep needs a real repo at the search base; an immutable corpus snapshot has no
# `.git`, so gitgrep drops out cleanly there rather than misfiring against a parent repo.
have git && [[ -d "${CORPUS}/.git" ]] && HAVE_GITGREP=1
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
  local exe_src="${REPO}/zig-out/bin/gist"
  [[ -x "${exe_src}" ]] || {
    echo "  no installed gist CLI at ${exe_src} — run zig build first"
    return 1
  }
  mkdir -p "$(dirname "${GIST_BIN}")"
  cp "${exe_src}" "${GIST_BIN}"
  command -v codesign > /dev/null 2>&1 && codesign --force --sign - "${GIST_BIN}" > /dev/null 2>&1
  # Stage the relate face beside it when built (same cp + re-sign rationale).
  local relate_src="${REPO}/zig-out/bin/relate"
  if [[ -x "${relate_src}" ]]; then
    cp "${relate_src}" "${RELATE_BIN}"
    command -v codesign > /dev/null 2>&1 && codesign --force --sign - "${RELATE_BIN}" > /dev/null 2>&1
  fi
  return 0
}

compete_build_gist_index() {
  (cd "${REPO}" && zig build -Doptimize=ReleaseFast) || return 1
  compete_install_gist_bin || return 1
  (cd "${CORPUS}" && "${GIST_BIN}" index) || return 1
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
  (cd "${CORPUS}" && xargs -0 -n 400 env CSEARCHINDEX="${CSEARCH_IDX}" cindex < "${PATHS_LIST}" > /dev/null 2>&1)
  t1="$(python3 -c 'import time;print(time.time())')"
  secs="$(python3 -c "print('%.1f'%(${t1}-${t0}))")"
  bytes="$(stat -f%z "${CSEARCH_IDX}" 2> /dev/null || stat -c%s "${CSEARCH_IDX}" 2> /dev/null || echo 0)"
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
  (cd "${CORPUS}" && zoekt-index -index "${ZOEKT_DIR}" -ignore_dirs "${ign}" "${ROOTS[@]}" > /dev/null 2>&1)
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
