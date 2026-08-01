#!/usr/bin/env bash
# fetch.sh — install the pinned multi-corpus battery into .local/gist-corpora/.
#
# Every performance and correctness claim in bench/ was historically measured on
# ONE corpus (a large host monorepo, one machine). This fetcher materializes trees
# with genuinely different shapes so the differential sweep (sweep.py) can hunt
# divergences the home corpus can never expose:
#
#   linux       C at scale — ~90k files, ~1.5 GiB, deep dirs, huge generated
#               headers. The classic ripgrep benchsuite tree.
#   cpython     Python + C — Lib/test ships deliberately broken encodings,
#               odd filenames, .gitignore'd fixtures.
#   typescript  Monster single files (checker.ts ~3 MiB — past gist's 4 MiB
#               read path shapes) + ~60k tiny baseline fixtures: both extremes
#               of the file-size distribution in one tree.
#   subtitles   OpenSubtitles en+ru monolingual samples (ripgrep's own perf
#               corpus): ONE giant line-oriented text file per language — no
#               tree walk at all, pure scan throughput + real Cyrillic for the
#               Unicode fold/class surface.
#   torture     Generated adversarial tree (torture.py, deterministic): match
#               at the 4 MiB cap edge, >4 MiB single line, chunk straddles,
#               symlink cycles, deep nesting, CRLF, UTF-16, invalid UTF-8,
#               NUL binaries, gitignore hierarchies, weird filenames.
#
# Pins are exact tags / fixed byte-counts so two machines build byte-identical
# corpora (subtitles: same URL + same decompressed prefix length). Everything
# lands under .local/ (machine-local, gitignored); re-running is idempotent —
# a corpus that already exists is verified + skipped, never re-downloaded.
#
# Usage:  bench/corpora/fetch.sh [name…]     # default: all five
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../roots.sh
source "${HERE}/../roots.sh"
gist_resolve_roots "${HERE}" || exit 1
DEST="${GIST_CORPORA_DIR:-${REPO}/.local/gist-corpora}"
mkdir -p "${DEST}"

# name → repo-url tag  (shallow, single-branch: the tree, not the history)
LINUX_URL="https://github.com/torvalds/linux" LINUX_TAG="v6.10"
CPYTHON_URL="https://github.com/python/cpython" CPYTHON_TAG="v3.13.0"
TS_URL="https://github.com/microsoft/TypeScript" TS_TAG="v5.8.3"
# OpenSubtitles v2016 monolingual dumps (the ripgrep benchsuite URLs). The full
# decompressed files are ~9 GiB / ~2.5 GiB; we keep a fixed-length prefix — the
# pipeline cut (head -c) aborts the download early, so only the needed
# compressed bytes transfer.
SUB_EN_URL="https://object.pouta.csc.fi/OPUS-OpenSubtitles/v2016/mono/en.txt.gz"
SUB_RU_URL="https://object.pouta.csc.fi/OPUS-OpenSubtitles/v2016/mono/ru.txt.gz"
SUB_BYTES=$((256 * 1024 * 1024)) # 256 MiB per language

clone_pinned() { # <dir> <url> <tag>
  local dir="${DEST}/$1" url="$2" tag="$3"
  if [[ -f "${dir}/.corpus-ready" ]]; then
    local ready
    ready="$(cat "${dir}/.corpus-ready")"
    echo "  $1: ready (${ready})"
    return 0
  fi
  rm -rf "${dir}"
  echo "  $1: cloning ${url} @ ${tag} (shallow)…"
  git clone --quiet --depth 1 --single-branch --branch "${tag}" "${url}" "${dir}" || return 1
  echo "${tag}" > "${dir}/.corpus-ready"
}

fetch_subtitles() {
  local dir="${DEST}/subtitles"
  if [[ -f "${dir}/.corpus-ready" ]]; then
    local ready
    ready="$(cat "${dir}/.corpus-ready")"
    echo "  subtitles: ready (${ready})"
    return 0
  fi
  rm -rf "${dir}"
  mkdir -p "${dir}"
  local lang url
  for lang in en ru; do
    url="$([[ "${lang}" = en ]] && echo "${SUB_EN_URL}" || echo "${SUB_RU_URL}")"
    echo "  subtitles: streaming ${lang} prefix (${SUB_BYTES} bytes decompressed)…"
    # head's early exit SIGPIPEs the pipeline once the prefix is complete —
    # curl stops transferring; the byte count (not curl's status) is the gate.
    curl -fsSL "${url}" 2> /dev/null | gzip -dc 2> /dev/null | head -c "${SUB_BYTES}" > "${dir}/${lang}.txt"
    local got
    got="$(wc -c < "${dir}/${lang}.txt" | tr -d ' ')"
    if [[ "${got}" != "${SUB_BYTES}" ]]; then
      echo "  subtitles: ${lang} short read (${got}/${SUB_BYTES} bytes) — network failure?" >&2
      rm -rf "${dir}"
      return 1
    fi
  done
  echo "v2016 en+ru ${SUB_BYTES}B prefixes" > "${dir}/.corpus-ready"
}

fetch_torture() {
  local dir="${DEST}/torture"
  if [[ -f "${dir}/.corpus-ready" ]]; then
    local ready
    ready="$(cat "${dir}/.corpus-ready")"
    echo "  torture: ready (${ready})"
    return 0
  fi
  rm -rf "${dir}"
  echo "  torture: generating adversarial tree (torture.py)…"
  python3 "${HERE}/torture.py" "${dir}" || return 1
  echo "torture.py deterministic build" > "${dir}/.corpus-ready"
}

WANT=("$@")
[[ ${#WANT[@]} -eq 0 ]] && WANT=(linux cpython typescript subtitles torture)
rc=0
for name in "${WANT[@]}"; do
  case "${name}" in
    linux) clone_pinned linux "${LINUX_URL}" "${LINUX_TAG}" || rc=1 ;;
    cpython) clone_pinned cpython "${CPYTHON_URL}" "${CPYTHON_TAG}" || rc=1 ;;
    typescript) clone_pinned typescript "${TS_URL}" "${TS_TAG}" || rc=1 ;;
    subtitles) fetch_subtitles || rc=1 ;;
    torture) fetch_torture || rc=1 ;;
    *)
      echo "unknown corpus '${name}' (linux cpython typescript subtitles torture)" >&2
      rc=1
      ;;
  esac
done
exit "${rc}"
