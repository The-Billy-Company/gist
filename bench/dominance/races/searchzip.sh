#!/usr/bin/env bash
# gist vs the field — the SEARCH-ZIP (`-z`) cold head-to-head, over a corpus of
# compressed files, every engine on its transparent-decompression path.
#
# This is the tier the other races can't touch: they search the repo's *plain*
# bytes, but `-z` first decompresses each file. gist's edge is architectural — it
# decodes the common formats (gzip, zstd, xz) IN-PROCESS via Zig's `std.compress`,
# one allocation-light streaming decode per file, while ripgrep and ugrep shell an
# external decompressor (`gzip -dc`, `xz -dc`, …) — a fork + exec + pipe per file.
# Over a many-file corpus that per-file process cost dominates, so the honest race
# is "search N compressed files," not "decode one big archive."
#
# Field: gist vs rg vs ugrep (the transparent-`-z` scanners). csearch/zoekt/ag have
# no `-z`, so they don't compete on this tier. rg remains gist's byte-exact oracle
# (regex_headtohead.sh proves the match sets agree); here we time the decode+scan.
#
# Corpus: a synthetic, deterministic source-like tree (COUNT files × formats), so
# the race reproduces without depending on the coworker-mutated repo tree. Usage:
#   bench/races/searchzip_headtohead.sh            (COUNT=400 RUNS=8)
#   COUNT=800 RUNS=12 bench/races/searchzip_headtohead.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_compete.sh
source "${HERE}/_compete.sh"
need_hyperfine

COUNT="${COUNT:-400}"
RUNS="${RUNS:-8}"
PATTERN='needle 3$' # a selective per-line match (regex, byte semantics)
WORK="${COMPETE_DIR}/searchzip"
rm -rf "${WORK}"
mkdir -p "${WORK}"

echo "building gist (ReleaseFast) + installing the binary…"
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast > /dev/null 2>&1) || {
  echo "  build failed (engine may be mid-refactor by a coworker) — aborting"
  exit 1
}
compete_install_gist_bin || exit 1

# The formats gist decodes in-process (the win) plus the external-tool tail; a
# format is raced only when its encoder exists to mint the corpus.
declare -a FORMATS
have gzip && FORMATS+=("gz:gzip -nc")
have zstd && FORMATS+=("zst:zstd -q -c")
have xz && FORMATS+=("xz:xz -c")
have bzip2 && FORMATS+=("bz2:bzip2 -c")
[[ "${#FORMATS[@]}" -gt 0 ]] || {
  echo "no compressors on PATH — cannot mint a -z corpus"
  exit 1
}

# Nested across subdirs (~16 files each), not one flat dir: gist's pipeline steals
# work at DIRECTORY granularity, so a flat corpus pins it to a single worker while
# the field parallelizes — a layout artifact, not a decode result. A source/log
# tree is many-dir, so the corpus is too; the race then times the honest thing
# (per-file decode + scan), each tool on its real parallelism.
FILES_PER_DIR=16
echo "minting ${COUNT} files/format under ${WORK} (nested, ${FILES_PER_DIR}/dir) …"
one_file() { # deterministic per-index source body
  local i="$1" j
  for j in $(seq 1 200); do
    echo "line ${j} of file ${i} with an occasional needle $((j % 37))"
  done
}
for spec in "${FORMATS[@]}"; do
  ext="${spec%%:*}"
  enc="${spec#*:}"
  for i in $(seq 1 "${COUNT}"); do
    sub="${WORK}/${ext}/sub$(((i - 1) / FILES_PER_DIR))"
    mkdir -p "${sub}"
    one_file "${i}" | ${enc} > "${sub}/f${i}.txt.${ext}" 2> /dev/null
  done
done

# The transparent-`-z` field. gist + rg always; ugrep when present.
tools=(gist rg)
have ugrep && tools+=(ugrep)

zip_cmd() { # <tool> <dir> — count-only, recursive, transparent decompression
  case "$1" in
    gist) echo "${GIST_BIN} -z -c '${PATTERN}' '$2'" ;;
    rg) echo "rg -z -c '(?-u)${PATTERN}' '$2'" ;;
    ugrep) echo "ugrep -z -c -r -P -- '${PATTERN}' '$2'" ;;
    *) echo false ;;
  esac
}

cd "${REPO}" || exit 1
echo
echo "cold -z query — fresh process over ${COUNT} compressed files (hyperfine mean, runs=${RUNS}):"
echo "fields: <tool> <ms> (<gist speedup>)"
echo
csv="${COMPETE_DIR}/searchzip.csv"
echo "format,tool,ms,gist_ms,ratio" > "${csv}"

declare -A SUM CNT WINS
for t in "${tools[@]}"; do
  SUM[${t}]=0
  CNT[${t}]=0
  WINS[${t}]=0
done

for spec in "${FORMATS[@]}"; do
  ext="${spec%%:*}"
  dir="${WORK}/${ext}"
  gcmd="$(zip_cmd gist "${dir}")"
  if ! gist_ms="$(hf_mean 3 "${RUNS}" "${gcmd}")"; then
    echo "aborting: gist failed status precheck for -z ${ext}" >&2
    exit 1
  fi
  printf "%-6s gist %sms\n" "${ext}" "${gist_ms}"
  line="    field:"
  for t in "${tools[@]}"; do
    cmd="$(zip_cmd "${t}" "${dir}")"
    if ! ms="$(hf_mean 2 "${RUNS}" "${cmd}")"; then
      echo "aborting: ${t} hard-failed while benchmarking -z ${ext}" >&2
      exit 1
    fi
    spd="$(ratio "${ms}" "${gist_ms}")"
    echo "${ext},${t},${ms},${gist_ms},${spd}" >> "${csv}"
    if [[ "${ms}" != "?" && "${gist_ms}" != "?" ]]; then
      SUM[${t}]="$(python3 -c "import math;print(${SUM[${t}]}+math.log(${ms}/${gist_ms}))")"
      CNT[${t}]=$((CNT[${t}] + 1))
      python3 -c "import sys;sys.exit(0 if ${ms}>=${gist_ms} else 1)" && WINS[${t}]=$((WINS[${t}] + 1))
    fi
    line+=" $(printf '%s %s(%s)' "${t}" "${ms}" "${spd}")"
  done
  echo "${line}"
done

echo
echo "── summary: geomean gist speedup · formats gist ≥ tool ──"
for t in "${tools[@]}"; do
  [[ "${CNT[${t}]}" -eq 0 ]] && continue
  g="$(python3 -c "import math;print('%.1f'%math.exp(${SUM[${t}]}/${CNT[${t}]}))")"
  printf "  %-8s %sx geomean · gist ≥ on %d/%d\n" "${t}" "${g}" "${WINS[${t}]}" "${CNT[${t}]}"
done
echo "gist decodes gzip/zstd/xz in-process; rg/ugrep fork a decompressor per file —"
echo "the per-file process cost is what gist erases. csv → ${csv}"
