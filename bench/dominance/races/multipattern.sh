#!/usr/bin/env bash
# multipattern.sh — Layer K: simultaneous multi-pattern matching vs Hyperscan.
#
# The question is not "can gist grep". It is the one Hyperscan (Intel; portable
# fork **Vectorscan**, NEON/SVE) was built for and is the reference on: compile N
# expressions into one matcher, walk bytes once, and report WHICH expression hit
# — expression-ID attribution at throughput. gist's surface for it is
# `PatternSet` (`src/kernel/slate/`), shipped as `relate patterns -e P -e P …`.
#
# TWO RACES, because there are two questions and only one of them is the user's:
#
#   arm 1 · PER BYTE (Hyperscan's home turf).  Both matchers over ONE resident
#           blob — `bench/multipattern/pack.py` packs it from gist's own
#           `paths.list`, so the bytes and their order are identical and neither
#           side pays for a tree walk. Swept over N, because the whole claim is
#           about how cost scales with the size of the question.
#
#   arm 2 · END TO END (the actual workload).  "Find these N patterns across the
#           corpus." Hyperscan is a STREAM scanner: it must touch every byte of
#           every file, and no per-byte speed can recover the bytes it cannot
#           skip. gist has an index. Four honest strategies race:
#
#             gist patterns   one walk, index-filtered, attributed  ← the claim
#             vectorscan      one automaton over every byte, attributed
#             rg alternation  one walk, fast, and CANNOT say which pattern hit
#             rg × N          N processes, attributed, N tree walks
#
#           `rg alternation` is in the field precisely because it is what a real
#           engineer types, and its column is a reminder that it answers a
#           WEAKER question — the attribution has to be re-derived afterwards.
#
# Vectorscan is a COMPETITOR, never a dependency: it is found via `pkg-config
# libhs` (brew install vectorscan), built into `.local/`, and when it is absent
# every Vectorscan cell is skipped with a stated reason. A certificate that
# fabricates a rival is worse than one that admits a missing column.
#
# Fail-closed on meaning before speed: gist's arm re-derives the whole
# attribution vector with N INDEPENDENT single-pattern searches (`--verify`) and
# the two tools' per-pattern document counts are diffed against each other. A
# timing that does not agree on the ANSWER is not published.
#
# Usage:  bench/races/multipattern.sh [-n N,N,…] [-m MiB] [ROOT...]
# Env:    MULTIPATTERN_OUT=DIR   where results land (default .local/gist-compete/multipattern)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=field.sh
source "${HERE}/field.sh"
need_hyperfine

# The sweep has to span both tiers and the crossing between them, or it cannot
# support a tier decision: 4–16 is the dragnet's regime, 16 is where the two
# curves meet, and 32–1024 is the trawl's. The tail rows are also where
# Vectorscan's own strategy switch shows up, so dropping them would quietly
# delete the only band it still wins.
NS="4,8,16,32,64,128,256,512,1024"
MIB=64
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n)
      NS="$2"
      shift 2
      ;;
    -m)
      MIB="$2"
      shift 2
      ;;
    *) break ;;
  esac
done
[[ $# -gt 0 ]] && ROOTS=("$@")

WORK="${MULTIPATTERN_OUT:-${COMPETE_DIR}/multipattern}"
BLOB="${WORK}/blob"
RAW="${WORK}/raw"
rm -rf "${WORK}"
mkdir -p "${BLOB}" "${RAW}"
PERBYTE="${WORK}/perbyte.tsv"
: > "${PERBYTE}"

# ── the slate ────────────────────────────────────────────────────────────────
# Mined from the packed corpus by `bench/multipattern/slate.py`, not hand-written.
# It is a fixed ordering, so any PREFIX of length N is itself a sensible slate —
# that is what makes the sweep a sweep and not nine unrelated benchmarks — and
# every literal genuinely occurs, so the rows measure the match path and not just
# the miss path. Plain literals, so `hs_compile_lit_multi` and gist's `-F` compile
# the same thing and the per-byte race is matcher-vs-matcher.
#
# Populated after the corpus is packed (below), since it reads those bytes.
PATS=()

# ── Vectorscan: found, built, or skipped with a reason ───────────────────────
VSCAN_BIN="${COMPETE_DIR}/vscan"
HAVE_VSCAN=0
VSCAN_WHY="not attempted"
VSCAN_VERSION="n/a"
build_vscan() {
  local src="${KERNEL}/bench/multipattern/vscan.c"
  [[ -f "${src}" ]] || {
    VSCAN_WHY="missing ${src}"
    return 1
  }
  have pkg-config || {
    VSCAN_WHY="no pkg-config — cannot locate libhs"
    return 1
  }
  local cflags libs
  cflags="$(pkg-config --cflags libhs 2> /dev/null)" || {
    VSCAN_WHY="pkg-config found no libhs (brew install vectorscan)"
    return 1
  }
  libs="$(pkg-config --libs libhs 2> /dev/null)"
  mkdir -p "${COMPETE_DIR}"
  # shellcheck disable=SC2086 # pkg-config output is a deliberate flag list
  cc -O3 -o "${VSCAN_BIN}" "${src}" ${cflags} ${libs} 2> "${WORK}/vscan-build.log" || {
    VSCAN_WHY="compile failed (see ${WORK}/vscan-build.log)"
    return 1
  }
  VSCAN_VERSION="$(pkg-config --modversion libhs 2> /dev/null || echo unknown)"
  HAVE_VSCAN=1
  VSCAN_WHY="ok"
}
build_vscan || true

# ── build gist + the multipattern arm, and index the corpus ─────────────────
echo "building gist + multipattern arm…"
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast multipattern -- --help > /dev/null 2>&1) || true
compete_build_gist_index || exit 1
MP_BIN="${KERNEL}/zig-out/bin/multipattern"
[[ -x "${MP_BIN}" ]] || {
  echo "multipattern: no arm binary at ${MP_BIN} — run: zig build -Doptimize=ReleaseFast lab" >&2
  exit 1
}

echo "packing the shared blob (${MIB} MiB from gist's own paths.list)…"
python3 "${KERNEL}/bench/multipattern/pack.py" \
  --out "${BLOB}" --paths "${PATHS_LIST}" --base "${CORPUS}" --mib "${MIB}" || exit 1
[[ -s "${BLOB}/corpus.bin" ]] || {
  echo "multipattern: packer produced no blob" >&2
  exit 1
}

# gist persists `paths.list` NUL-separated; the stream-scanner arm reads a
# newline-separated list. Same corpus, one translation, so arm 2's Vectorscan
# column walks exactly the file set gist's index was built over.
PATHS_LIST_NL="${WORK}/paths.lines"
python3 - "${PATHS_LIST}" "${CORPUS}" "${PATHS_LIST_NL}" << 'PY'
import pathlib
import sys

src, base, dst = (pathlib.Path(a) for a in sys.argv[1:4])
names = [p for p in src.read_bytes().split(b"\0") if p]
dst.write_text("".join(f"{base / p.decode('utf-8', 'surrogateescape')}\n" for p in names))
print(f"  {len(names)} paths → {dst}")
PY

# ── the slate, mined from the bytes just packed ──────────────────────────────
# Widest requested N decides how many literals to mine; every shorter row is a
# prefix of the same ordering.
SLATE_WANT="$(printf '%s\n' "${NS//,/ }" | tr ' ' '\n' | sort -n | tail -1)"
SLATE_FILE="${WORK}/slate.txt"
# Materialized rather than piped into `mapfile`, so the miner's exit code is
# checked directly instead of inferred from an empty array — a slate that came up
# short for a reportable reason and one that failed outright are different faults.
python3 "${KERNEL}/bench/multipattern/slate.py" \
  --corpus "${BLOB}" -n "${SLATE_WANT}" > "${SLATE_FILE}" || {
  echo "multipattern: slate.py could not mine a slate from the packed corpus" >&2
  exit 1
}
mapfile -t PATS < "${SLATE_FILE}"
[[ "${#PATS[@]}" -gt 0 ]] || {
  echo "multipattern: slate.py mined no literals from the packed corpus" >&2
  exit 1
}
# Recorded so a reader can tell whether two mints raced the same slate — the
# corpus is a live tree, so the slate is reproducible from it but not eternal.
SLATE_DIGEST="$(python3 "${KERNEL}/bench/multipattern/slate.py" \
  --corpus "${BLOB}" -n "${SLATE_WANT}" --digest)"
echo "  slate: ${SLATE_DIGEST%% *} literals, sha256 ${SLATE_DIGEST##* }"

# ── arm 1: per-byte throughput, swept over N ────────────────────────────────
# Each row: N, gist GB/s, vectorscan GB/s, `--verify` verdict, cross-tool
# attribution verdict, the tier that answered, and the `--verify` verdict of the
# tier that did NOT. The report reads only this file for arm 1.
#
# Both tiers are verified at every N on purpose. gist dispatches on slate width
# (`muster.trawl_from`), so a single verified run only proves whichever mechanism
# the threshold happened to pick — and then moving the threshold, which is a
# tuning decision, would silently move which code was ever proven exact. Forcing
# the other side with `GIST_MUSTER_TIER` closes that: at every N, the dragnet and
# the trawl each reproduce N independent single-pattern searches.
echo
echo "arm 1 — per-byte throughput over the shared blob"
printf "  %4s  %10s  %11s  %-8s %-8s %-9s %s\n" \
  N "gist GB/s" "vscan GB/s" verify tier "alt-tier" attribution
IFS=',' read -ra N_LIST <<< "${NS}"
for n in "${N_LIST[@]}"; do
  [[ "${n}" -le "${#PATS[@]}" ]] || {
    echo "  N=${n} skipped: slate holds only ${#PATS[@]} patterns"
    continue
  }
  flags=()
  for ((i = 0; i < n; i++)); do flags+=(-e "${PATS[i]}"); done

  gist_json="${RAW}/perbyte-gist-${n}.json"
  if ! "${MP_BIN}" --corpus "${BLOB}" -F --verify --reps 3 "${flags[@]}" > "${gist_json}" 2>&1; then
    echo "  N=${n}: gist arm FAILED (attribution mismatch or error):" >&2
    sed 's/^/    /' "${gist_json}" >&2
    exit 1
  fi
  gist_gbps="$(python3 -c 'import json,sys;print(f"{json.load(open(sys.argv[1]))["gbps"]:.3f}")' "${gist_json}")"
  verified="$(python3 -c 'import json,sys;print("yes" if json.load(open(sys.argv[1]))["verified"] else "no")' "${gist_json}")"
  tier="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tier"])' "${gist_json}")"

  # The mechanism the threshold did NOT pick, held to the same oracle.
  case "${tier}" in
    trawl) alt_tier="dragnet" ;;
    dragnet) alt_tier="trawl" ;;
    *) alt_tier="" ;;
  esac
  alt="n/a"
  if [[ -n "${alt_tier}" ]]; then
    alt_json="${RAW}/perbyte-gist-${n}-${alt_tier}.json"
    if GIST_MUSTER_TIER="${alt_tier}" "${MP_BIN}" --corpus "${BLOB}" -F --verify --reps 1 \
      "${flags[@]}" > "${alt_json}" 2>&1; then
      # It must have actually built the tier we asked for; a silently-ignored
      # override would make this column a rubber stamp.
      got="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tier"])' "${alt_json}")"
      alt="$([[ "${got}" = "${alt_tier}" ]] && echo yes || echo "NOT-FORCED")"
    else
      echo "  N=${n}: forced-${alt_tier} arm FAILED (attribution mismatch):" >&2
      sed 's/^/    /' "${alt_json}" >&2
      exit 1
    fi
  fi

  vs_gbps="skip"
  cross="skip"
  if [[ "${HAVE_VSCAN}" = 1 ]]; then
    vs_json="${RAW}/perbyte-vscan-${n}.json"
    if "${VSCAN_BIN}" --corpus "${BLOB}" -F "${flags[@]}" > "${vs_json}" 2>&1; then
      vs_gbps="$(python3 -c 'import json,sys;print(f"{json.load(open(sys.argv[1]))["gbps"]:.3f}")' "${vs_json}")"
      cross="$(
        python3 - "${gist_json}" "${vs_json}" << 'PY'
import json
import sys

a = json.load(open(sys.argv[1]))["doc_hits"]
b = json.load(open(sys.argv[2]))["doc_hits"]
print("equal" if a == b else "MISMATCH")
PY
      )"
    else
      vs_gbps="fail"
      cross="fail"
    fi
  fi
  printf "  %4s  %10s  %11s  %-8s %-8s %-9s %s\n" \
    "${n}" "${gist_gbps}" "${vs_gbps}" "${verified}" "${tier}" "${alt}" "${cross}"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${n}" "${gist_gbps}" "${vs_gbps}" "${verified}" "${cross}" "${tier}" "${alt}" >> "${PERBYTE}"
done
[[ "${HAVE_VSCAN}" = 1 ]] || echo "  vectorscan column SKIPPED: ${VSCAN_WHY}"

# ── arm 2: end-to-end corpus search ─────────────────────────────────────────
# The workload the surface exists for, at the N a human actually types. Every
# arm is timed as a whole process, warm page cache, same roots.
E2E_N="${MULTIPATTERN_E2E_N:-10}"

# Arm 2's slate is drawn from a SELECTIVITY BAND, not from the head of the token
# distribution, and the distinction decides what this arm measures.
#
# Corpus token frequency is not query frequency. An agent sweeps for
# `WalletService` or `PatternSet`; nobody asks a multi-pattern surface to find
# `string`. Draw ten literals from the raw distribution and one of them occurs
# ~49,000 times, so every strategy must emit ~112,000 attributed lines and the
# arm degenerates into a measurement of line formatting — the index has nothing
# left to skip. Measured, that single substitution moved gist-vs-Vectorscan from
# 4.3x to 1.21x while the code was byte-identical. Capping occurrences models the
# symbol query the surface actually serves.
#
# The uncapped case is not hidden for being unflattering: it runs below as the
# `*_broad` pair, so both regimes are published from one mint.
E2E_SLATE="${WORK}/slate-e2e.txt"
python3 "${KERNEL}/bench/multipattern/slate.py" \
  --corpus "${BLOB}" -n "${E2E_N}" --max-count "${MULTIPATTERN_E2E_MAX_COUNT:-200}" \
  > "${E2E_SLATE}" || {
  echo "multipattern: could not mine a selective slate for arm 2" >&2
  exit 1
}
mapfile -t E2E_PATS < "${E2E_SLATE}"
[[ "${#E2E_PATS[@]}" -eq "${E2E_N}" ]] || {
  echo "multipattern: arm-2 slate holds ${#E2E_PATS[@]} literals, wanted ${E2E_N}" >&2
  exit 1
}

e2e_flags=""
e2e_alt=""
e2e_seq=""
for p in "${E2E_PATS[@]}"; do
  e2e_flags+=" -e '${p}'"
  e2e_alt+="${e2e_alt:+|}(?:${p})"
  e2e_seq+="rg -F -l --sort none ${SCOPE} -- '${p}' ${ROOTS[*]} >/dev/null; "
done

# The adverse slate: the same width, drawn from the unrestricted distribution, so
# it necessarily includes a near-ubiquitous token.
broad_flags=""
for ((i = 0; i < E2E_N; i++)); do broad_flags+=" -e '${PATS[i]}'"; done

echo
echo "arm 2 — end-to-end: ${E2E_N} patterns across the corpus"
# ROOTS are relative to the corpus base, so every arm-2 command must run FROM it.
# Without this the tree walk finds nothing and each column reports the speed of
# searching an empty set — the most plausible-looking wrong number in the file.
cd "${CORPUS}" || exit 1
# GIST_NO_KEEP=1 is load-bearing, not hygiene. When a `gist serve` daemon is
# resident, the seven pure relate verbs consult its answer keep, which returns a
# byte-identical rendered stdout for a query already asked against an unchanged
# corpus. The gate below asks this exact query first, so hyperfine would then
# time ten memoized recalls: measured 0.00 s warm against 0.14 s of real work,
# which would publish a ~180x win over Vectorscan that is a hash lookup racing a
# search. The keep is a real gist feature and stays on in normal use; it is
# simply not what this arm claims to measure, and no competitor here has one.
gist_e2e="GIST_NO_KEEP=1 ${RELATE_BIN} patterns -F ${e2e_flags} --by pattern ${ROOTS[*]}"
hits="$(bash -c "${gist_e2e}" 2> /dev/null | wc -l | tr -d ' ')"
[[ "${hits}" -gt 0 ]] || {
  echo "multipattern: gist's end-to-end arm matched nothing under ${CORPUS} — refusing to time an empty corpus" >&2
  exit 1
}
# Arm 2's answer is gated before it is timed, because a 60x win over a stream
# scanner is only interesting if the fused walk answered the same question the
# slow way would have. The oracle is the contract itself: N independent
# single-pattern runs of the same binary, one process per pattern, so the
# N-pattern fused path (muster armed, one walk, attribution reconstructed) is
# compared against the trivial single-query path that has no set machinery in it
# at all. Byte equality of the full attributed stream is demanded — not counts,
# which would let a swapped attribution through.
#
# Deliberately NOT gated against rg here, though rg is still timed below. rg
# walks the live tree while `relate patterns` answers over the indexed corpus,
# and the two corpora genuinely differ: the indexer prunes `vendor/` where the
# walk keeps it (470 of rg's 592 hits for a vendored literal), so a like-for-like
# reports 592 and `relate patterns` reports 122. Gating on rg equality would
# either fail forever on a scope difference or, worse, invite someone to "fix" it
# by intersecting with `paths.list` — a stale snapshot that also drops every file
# created after the last index write, silently discarding real answers. The
# cross-tool attribution check that IS sound lives in arm 1, where both engines
# read one identical in-memory blob and there is no corpus question to confuse.
echo "  gating arm 2's answer against ${E2E_N} independent single-pattern runs…"
bash -c "${RELATE_BIN} patterns -F ${e2e_flags} ${ROOTS[*]}" 2> /dev/null \
  | LC_ALL=C sort -u > "${WORK}/together.txt"
: > "${WORK}/apart.txt"
for p in "${E2E_PATS[@]}"; do
  bash -c "${RELATE_BIN} patterns -F -e '${p}' ${ROOTS[*]}" 2> /dev/null >> "${WORK}/apart.txt"
done
LC_ALL=C sort -u "${WORK}/apart.txt" -o "${WORK}/apart.txt"
if ! cmp -s "${WORK}/together.txt" "${WORK}/apart.txt"; then
  echo "    ATTRIBUTION MISMATCH: one fused walk != ${E2E_N} independent runs" >&2
  diff "${WORK}/together.txt" "${WORK}/apart.txt" | head -20 >&2
  echo "multipattern: arm 2 broke the exactness contract — refusing to publish a timing" >&2
  exit 1
fi
attributed_lines="$(wc -l < "${WORK}/together.txt")"
echo "    equal: ${attributed_lines// /} attributed lines, byte-identical either way"
# The timed gist column reports `--by pattern`, so it emits one aggregate row per
# pattern rather than every hit — the same output shape as rg's `-l`, which is
# what makes the two columns a fair pairing. `hits` is therefore N, not the match
# count; the attributed stream those rows summarize is the file compared above.
echo "  (scoped to ${CORPUS}; gist emits ${hits} per-pattern rows, keep disabled)"
# Tool ids are the contract with the report: it reads `${RAW}/e2e-<id>.json` and
# owns the display labels, so a missing competitor is simply an absent file.
time_e2e() { # <id> <label> <cmd>
  local label="$2" cmd="$3" js="${RAW}/e2e-$1.json"
  if compete_hyperfine --warmup 1 --runs 10 --export-json "${js}" "${cmd}" > /dev/null 2>&1; then
    local ms
    ms="$(python3 -c 'import json,sys;r=json.load(open(sys.argv[1]))["results"][0];t=sorted(r["times"]);print(f"{t[len(t)//2]*1000:.1f}")' "${js}")"
    printf "  %-34s %8s ms\n" "${label}" "${ms}"
  else
    printf "  %-34s %8s\n" "${label}" "FAILED"
    rm -f "${js}"
  fi
}

time_e2e gist "gist patterns (attributed)" "${gist_e2e} >/dev/null"
if [[ "${HAVE_VSCAN}" = 1 ]]; then
  time_e2e vectorscan "vectorscan (attributed, all bytes)" \
    "${VSCAN_BIN} --paths ${PATHS_LIST_NL} -F ${e2e_flags} >/dev/null"
else
  echo "  vectorscan (attributed, all bytes)   SKIPPED: ${VSCAN_WHY}"
fi
if [[ "${HAVE_RG}" = 1 ]]; then
  time_e2e rg_alt "rg alternation (NO attribution)" \
    "rg -l --sort none ${SCOPE} -- '${e2e_alt}' ${ROOTS[*]} >/dev/null"
  time_e2e rg_seq "rg × ${E2E_N} (attributed, N walks)" "${e2e_seq}"
else
  echo "  rg columns SKIPPED: ripgrep not installed"
fi

# The adverse regime, published from the same mint. Where the slate contains a
# near-ubiquitous literal there is nothing for an index to skip, both tools must
# emit the same very large answer, and gist's structural advantage largely
# evaporates. Printing it is the point: it bounds the claim above.
echo
echo "  adverse: same width, unrestricted slate (contains a ubiquitous literal)"
time_e2e gist_broad "gist patterns (broad slate)" \
  "GIST_NO_KEEP=1 ${RELATE_BIN} patterns -F --by pattern ${broad_flags} ${ROOTS[*]} >/dev/null"
if [[ "${HAVE_VSCAN}" = 1 ]]; then
  time_e2e vectorscan_broad "vectorscan (broad slate)" \
    "${VSCAN_BIN} --paths ${PATHS_LIST_NL} -F ${broad_flags} >/dev/null"
fi

# ── receipts ────────────────────────────────────────────────────────────────
python3 - "${WORK}/meta.json" << PY
import json
import pathlib

idx = pathlib.Path("${BLOB}/corpus.idx").read_text().splitlines()
bytes_total = sum(int(line.split("\t")[1]) for line in idx if line.strip())
json.dump(
    {
        "docs": len(idx),
        "bytes": bytes_total,
        "mib": ${MIB},
        "e2e_patterns": ${E2E_N},
        "slate": ${#PATS[@]},
        "slate_sha256": "${SLATE_DIGEST##* }",
        "vectorscan": {"available": ${HAVE_VSCAN}, "why": "${VSCAN_WHY}", "version": "${VSCAN_VERSION}"},
    },
    open("${WORK}/meta.json", "w"),
    indent=1,
)
PY

echo
echo "results  → ${PERBYTE}"
echo "raw      → ${RAW}"
echo "meta     → ${WORK}/meta.json"
echo
echo "certify: python3 bench/certify/certify_multipattern_report.py \\"
echo "           --perbyte ${PERBYTE} --raw ${RAW} --meta ${WORK}/meta.json \\"
echo "           --certificate <CERTIFICATE.md> --csv <multipattern.csv>"
