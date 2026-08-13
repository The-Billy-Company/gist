#!/usr/bin/env bash
# field.sh — the measurement floor every package's races and mints stand on.
# SOURCED, never executed.
#
# VENDORED, BYTE-IDENTICAL across all four ecosystem packages
# (`bench/apparatus/SHARED.sha256`, checked by `shared_drift.py`).
#
# WHAT IS SHARED IS THE APPARATUS, NEVER THE CLAIM. Three questions have the
# same answer in all four packages, and answering them twice is how two
# certificates stop being comparable:
#
#   1. WHAT IS THE CORPUS — which tree, scoped by which roots, minus which
#      build-output directories. A rival scoped even slightly differently is
#      racing a different question.
#   2. HOW DOES A RIVAL GET AN INDEX — csearch and zoekt are indexed tools, so
#      timing them without one is a strawman. Both are built here, over the
#      corpus the exact-search face itself indexed.
#   3. WHEN IS A TIMING HONEST — a cell is timed only after its output has been
#      proven equivalent to ripgrep's, and only through one hyperfine invocation
#      whose failure semantics are pinned.
#
# What each package RACES is its own: the per-tool command builders and the
# field roster live next to the races that use them (the exact-search package's
# are in `bench/dominance/races/field.sh`, which sources this file).
#
# Vocabulary — one meaning per name, ecosystem-wide (see `roots.sh`):
#   KERNEL   this package's checkout        CORPUS   the tree being measured
#   ENGINE   the irregex checkout           PRODUCT  the exact-search checkout
#   KINSHIP  the kinship checkout           OUT      the artifact home (.gist)
#
# Source it from a bench script after setting HERE to that script's directory:
#   # shellcheck source=../apparatus/field.sh
#   source "${HERE}/../../apparatus/field.sh"   # adjust depth
#
# Tool columns auto-skip when a binary is not installed. Install hints:
#   ugrep:   brew install ugrep
#   ggrep:   brew install grep          (GNU grep as `ggrep` on macOS)
#   csearch: go install github.com/google/codesearch/cmd/{cindex,csearch}@latest
#   zoekt:   go install github.com/sourcegraph/zoekt/cmd/{zoekt-index,zoekt}@latest

# The exact-search face's default output budget (the ~25k-token agent-context
# guard) would clip a repo-wide result and perturb the ripgrep oracle; every
# race/gate here diffs or times that face against rg's uncapped output, so lift
# the soft cap process-wide. The hard OOM ceiling stays on.
# (corpus.zig::initOutputBudget honors this env.)
export GIST_UNCAP=1

# ── locations ────────────────────────────────────────────────────────────────
FIELD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./roots.sh
source "${FIELD_HERE}/roots.sh"
gist_resolve_roots "${FIELD_HERE}" || return 1

# ── the declared corpus, when a mint named one ───────────────────────────────
# `CERT_CORPUS_ID` names a row in this package's `bench/certificate/corpus.toml`.
# The charter already states that corpus's `roots` and a `fetch` recipe a
# stranger can run, so the floor RUNS THE DECLARED RECIPE rather than any mint
# knowing what an id means. Adding a corpus is then a charter edit — no shell
# anywhere learns a new name, and two packages certifying over one id cannot
# drift into two different trees.
#
# WHETHER A CORPUS NEEDS MATERIALIZING IS SOMETHING ITS RECIPE ALREADY SAYS. A
# recipe naming an output directory (`… <dir>`) PRODUCES a tree, so it is run
# into `.local/corpus/<id>`; one that does not (`git clone …/<pkg>`) is telling a
# stranger how to obtain this package, which is what a self corpus is — measured
# in place, scoped to its declared roots.
#
# Not "are the declared roots present": `gist-synthetic-go-v1` declares
# `roots = ["."]`, and `.` is present in every directory on earth. That test
# would have quietly measured the exact-search checkout and stamped 16,000
# synthetic Go files on the bundle — the exact confusion this block exists
# to end.
if [[ -n "${CERT_CORPUS_ID:-}" ]]; then
  _field_publish="${KERNEL}/bench/certificate/guard/publish.py"
  if _field_roots="$(python3 "${_field_publish}" roots "${CERT_CORPUS_ID}")"; then
    _field_fetch="$(python3 "${_field_publish}" fetch "${CERT_CORPUS_ID}")" || return 1
    if [[ "${_field_fetch}" == *"<dir>"* && -z "${GIST_CORPUS_ROOT:-}" ]]; then
      GIST_CORPUS_ROOT="${KERNEL}/.local/corpus/${CERT_CORPUS_ID}"
      echo "materializing corpus ${CERT_CORPUS_ID} → ${GIST_CORPUS_ROOT}"
      (cd "${KERNEL}" && eval "${_field_fetch//<dir>/${GIST_CORPUS_ROOT}}") || {
        echo "field.sh: corpus ${CERT_CORPUS_ID} fetch recipe failed: ${_field_fetch}" >&2
        return 1
      }
      export GIST_CORPUS_ROOT
      # The bundle belongs to the PACKAGE, not to the tree being measured. Left
      # to default (`${CORPUS}/.gist`) a whole certificate would be written
      # inside the corpus — deleted by the next materialization, and counted
      # among the measured bytes in between.
      export GIST_DIR="${GIST_DIR:-${KERNEL}/.local/certificate}"
      gist_resolve_roots "${FIELD_HERE}" || return 1
    fi
    export GIST_ROOTS="${GIST_ROOTS:-${_field_roots}}"
  else
    echo "field.sh: CERT_CORPUS_ID=${CERT_CORPUS_ID} is not declared in corpus.toml" >&2
    return 1
  fi
fi

OUT="${GIST_VERIFY}"                        # the index + paths.list live here
# Pin the artifact home the Zig lanes resolve (`home.outDir()`) to the one this
# floor just decided, so a lane invoked from the package root and a splicer
# reading the bundle name the same directory. Unexported, GIST_VERIFY would
# resolve to ${CORPUS}/.gist here while a lane's CWD-relative `.gist` landed
# under the checkout — the fresh number written to one place and the stale one
# spliced from the other, with nothing in the certificate saying so.
export GIST_DIR="${OUT}"
COMPETE_DIR="${KERNEL}/.local/gist-compete" # competitor indices live here
GIST_BIN="${KERNEL}/.local/gist-bin"
RELATE_BIN="${KERNEL}/.local/relate-bin" # the compression-search face
CSEARCH_IDX="${COMPETE_DIR}/csearch.idx"
ZOEKT_DIR="${COMPETE_DIR}/zoekt"
PATHS_LIST="${OUT}/paths.list"

# Corpus scope: $GIST_ROOTS override (`:`/`,`/space separated), else the whole
# measured tree — mirrors `corpus.resolveRoots`.
#
# The default used to be the private monorepo's six top-level directories,
# sniffed for and used when they all happened to exist. That is the shape of
# default that decides what a certificate measured based on what was sitting on
# the disk, and every root it named is now a `[deny]` substring in every
# package's `corpus.toml` — a bundle scoped that way cannot be published at all.
# What a mint measures is stated by the caller (`GIST_ROOTS`, matching the
# `roots` of a declared corpus) or it is the corpus root; there is no third
# answer inferred from the neighborhood.
if [[ -n "${GIST_ROOTS:-}" ]]; then
  read -ra ROOTS <<< "${GIST_ROOTS//[:,]/ }"
else
  ROOTS=(.)
fi

# The tree about to be walked must BE the corpus a bundle will claim — both in
# what it is scoped to and in what is actually on the disk there. Checked here
# rather than only at publish, because publish is minutes later and a mint that
# never publishes skipped the check entirely: that is how a run with an
# inherited `GIST_CORPUS_ROOT` measured a 16,000-file Go corpus and labeled the
# bundle `ecosystem-v1` without a word.
if [[ -n "${CERT_CORPUS_ID:-}" ]]; then
  _field_absent=()
  for _r in "${ROOTS[@]}"; do [[ -e "${CORPUS}/${_r}" ]] || _field_absent+=("${_r}"); done
  if [[ "${ROOTS[*]}" != "${_field_roots}" || ${#_field_absent[@]} -gt 0 ]]; then
    echo "field.sh: corpus mismatch — CERT_CORPUS_ID=${CERT_CORPUS_ID} declares" >&2
    echo "  roots: ${_field_roots}" >&2
    echo "  but this run would walk: ${ROOTS[*]}  (under ${CORPUS})" >&2
    [[ ${#_field_absent[@]} -gt 0 ]] && echo "  missing there: ${_field_absent[*]}" >&2
    echo "Unset GIST_CORPUS_ROOT/GIST_ROOTS, or name the corpus you are really measuring." >&2
    return 1
  fi
fi

# Heavy build/cache dirs that have no per-file gitignore equivalent for ugrep /
# GNU grep / zoekt. Mirrors the exact-search face's own ignored-subtree set +
# the rule-of-five ignored dirs, so every tool is scoped to roughly the same
# logical corpus.
XDIRS=(node_modules target .venv venv __pycache__ .zig-cache zig-out dist
  dist-types build .build out .next coverage .turbo .mypy_cache .ruff_cache
  .pytest_cache Pods DerivedData .swiftpm vendor .local .cache .parcel-cache
  storybook-static xcuserdata graphify-out .pnpm-store .git .hg .svn)

# The exact-search face and rg run under `--no-ignore-vcs` for a deterministic
# multi-root oracle set, but that also discards every NESTED `.gitignore` —
# which silently re-admits build artifacts the root `.gitignore` never names:
# Elixir `_build`/`deps`/`cover` beam output and Electron `out/`. That face's
# own indexer prunes those, so they are absent from `paths.list` and therefore
# from csearch's corpus — racing the pair over a strict SUPERSET of the indexed
# rivals' corpus is not the like-for-like this file claims (measured: +2,488
# files, all build output, 1.47x on that face's `literal-rare` cell). Re-apply
# them as the glob equivalent of what XDIRS already gives the other no-gitignore
# tools. NOT the whole of XDIRS: a tracked `vendor/` tree can hold source the
# index admits, so a bare exclude would push that face BELOW the indexed corpus.
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
# The ignore scope the exact-search face and rg SHARE, resolved once: identical
# flags on both sides keep the rg-oracle gate honest (verified byte-identical
# `--files` sets).
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

# ── product binaries ─────────────────────────────────────────────────────────
# compete_install_gist_bin → copy the deterministic installed CLIs out of their
# OWNING checkouts. Never select a hash-named cache artifact by mtime: an older
# intermediate build can have a newer timestamp and silently invalidate every
# gate/certificate.
#
# The ad-hoc re-sign is load-bearing on macOS: `cp`-ing a Mach-O strips its
# ad-hoc code signature, and syspolicyd then SIGKILLs ("Killed: 9") the first
# exec(s) of the copy while it re-evaluates — which silently breaks a gate that
# runs the binary once (a later re-exec in the same script appears to "work",
# masking it). `codesign --sign -` re-stamps the copy so it runs on first exec.
# No-op where codesign is absent (Linux). Returns 1 if no exact-search binary
# was found.
compete_install_gist_bin() {
  local exe_src="${PRODUCT}/zig-out/bin/gist"
  [[ -x "${exe_src}" ]] || {
    echo "  no installed gist CLI at ${exe_src} — run zig build first"
    return 1
  }
  mkdir -p "$(dirname "${GIST_BIN}")"
  cp "${exe_src}" "${GIST_BIN}"
  command -v codesign > /dev/null 2>&1 && codesign --force --sign - "${GIST_BIN}" > /dev/null 2>&1
  # Stage the kinship face beside it when built (same cp + re-sign rationale).
  local relate_src="${KINSHIP}/zig-out/bin/relate"
  if [[ -x "${relate_src}" ]]; then
    cp "${relate_src}" "${RELATE_BIN}"
    command -v codesign > /dev/null 2>&1 && codesign --force --sign - "${RELATE_BIN}" > /dev/null 2>&1
  fi
  return 0
}

# Build the exact-search CLI in ITS checkout, then persist an index over the
# corpus. Upstream packages race against the shipped product, so the build has
# to happen where the product lives rather than wherever the caller happens to
# be.
compete_build_gist_index() {
  (cd "${PRODUCT}" && zig build -Doptimize=ReleaseFast) || return 1
  compete_install_gist_bin || return 1
  (cd "${CORPUS}" && "${GIST_BIN}" index) || return 1
}

# ── rival index construction (once per run) ──────────────────────────────────
# Build the csearch index over the exact-search face's EXACT corpus (the
# persisted paths.list), so the two trigram indexes cover byte-identical files.
# Prints build seconds + index size. Requires that face's index already
# persisted (paths.list present).
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

# Build the zoekt index over the ROOTS tree under the heavy ignore set. Zoekt has
# no file-list input, so its corpus is a documented superset: treat it as a
# production indexed *timing* reference, not a correctness oracle.
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
# before an exact-search cell may be timed. This is intentionally independent of
# order.
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
  # The same reader the splices use (`apparatus/hyperfine.py`) — a race that
  # printed one number and a certificate that parsed another from the same file
  # is a divergence no verdict math downstream can see.
  python3 "${FIELD_HERE}/hyperfine.py" "${js}" "${stat}"
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
