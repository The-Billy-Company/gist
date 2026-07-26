#!/usr/bin/env bash
# certify.sh — full Dominance-and-Fit Certificate (Layers A–F).
#
# Layer A has three lanes: microscopic (`zig build certify` — cycles/byte for the
# in-process verify kernel; auto-re-runs under sudo when available for PMU),
# macroscopic (this script's hyperfine race — cold fresh-process gist vs the
# field, fail-closed bootstrap-CI + Mann-Whitney vs ripgrep), the warm resident
# tier, and the `--rank` lane. Layers B/B′/C/D/E/F are then spliced automatically
# via `certify_layers.sh` so the committed artifact never ships a header that
# promises the layers and delivers one.
#
# The 12 classes are byte-identical to certify.zig's probes, so the macroscopic
# table and the microscopic table in CERTIFICATE.md map 1:1 by class name.
#
# Field + fairness scoping come from _compete.sh (same roots, same ignore set,
# each tool on its fastest honest path). gist + indexed rivals cold-load an index
# built ONCE over the same corpus; rg/ugrep/ag/grep re-walk + re-scan.
#
# Usage:  bench/certify/certify.sh            (RUNS=20 WARMUP=3 by default)
#         RUNS=40 bench/certify/certify.sh    (tighten the CIs)
#         CERT_SUDO=1 CERT_PUBLISH_DIR=bench/certify/artifact …
#         make bench-gist-certify             (B–E refresh; CERT_FULL=1 = this)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../races/_compete.sh
source "${HERE}/../races/_compete.sh"
need_hyperfine

# Refuse to mint a certificate whose machine.git_commit could not equal a clean
# HEAD — unless CERT_ALLOW_DIRTY=1 (local refresh / coworking trees).
if ! git -C "${REPO}" rev-parse --verify HEAD > /dev/null 2>&1; then
  echo "certificate aborted: cannot resolve git HEAD" >&2
  exit 1
fi
dirty="$(git -C "${REPO}" status --porcelain 2> /dev/null || true)"
if [[ -n "${dirty}" && "${CERT_ALLOW_DIRTY:-0}" != "1" ]]; then
  echo "certificate aborted: worktree is dirty — commit or isolate changes before certifying" >&2
  echo "(local refresh: CERT_ALLOW_DIRTY=1 …, or bash bench/certify/certify_layers.sh for B–E only)" >&2
  git -C "${REPO}" status --porcelain >&2
  exit 1
fi

RUNS="${RUNS:-20}"
WARMUP="${WARMUP:-3}"
WORK="${COMPETE_DIR}/certify"
CERT="${OUT}/CERTIFICATE.md"
MACRO_CSV="${OUT}/certify_macro.csv"
rm -rf "${WORK}"
mkdir -p "${WORK}" "${OUT}"

echo "measuring microscopic Layer A (ReleaseFast)…"
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast certify) || {
  echo "certificate aborted: microscopic certify run failed" >&2
  exit 1
}
[[ -s "${OUT}/certify.csv" ]] || {
  echo "certificate aborted: microscopic run did not emit ${OUT}/certify.csv" >&2
  exit 1
}
# PMU re-run BEFORE the macroscopic race — `gist-bench certify` rewrites the
# whole CERTIFICATE.md, so it must happen before macro/B/C/D splices. Uses
# passwordless sudo when available (CERT_SUDO=1 to prompt; CERT_SUDO=0 to skip).
BENCH_BIN="${KERNEL}/zig-out/bin/gist-bench"
if [[ -x "${BENCH_BIN}" ]] && ! grep -q 'cycles/byte provenance: \*\*measured on this machine\*\*' "${CERT}" 2> /dev/null; then
  case "${CERT_SUDO:-auto}" in
    0) echo "  CERT_SUDO=0 — Layer A micro stays wall-clock (no PMU)" ;;
    1)
      echo "  CERT_SUDO=1 — re-running microscopic Layer A under sudo for cycles…"
      (cd "${REPO}" && sudo "${BENCH_BIN}" certify) || {
        echo "certificate aborted: sudo microscopic certify failed" >&2
        exit 1
      }
      ;;
    *)
      if sudo -n true 2> /dev/null; then
        echo "  passwordless sudo — re-running microscopic Layer A under root for cycles…"
        (cd "${REPO}" && sudo -n "${BENCH_BIN}" certify) || {
          echo "certificate aborted: sudo -n microscopic certify failed" >&2
          exit 1
        }
      else
        echo "  no passwordless sudo — Layer A micro stays wall-clock (cycles labeled NOT measured)"
        echo "  tip: CERT_SUDO=1 bash bench/certify/certify.sh   # prompt once for PMU"
      fi
      ;;
  esac
fi

# class  kind  pattern — byte-identical to certify.zig's `probes` (patterns have
# no spaces, so `read class kind pat` recovers the pattern as the trailing field).
PROBES=(
  "literal-rare literal pgxpool"
  "literal-dotted literal context.Context"
  "literal-common literal func"
  "literal-punct2 literal })"
  "regex-decl regex func\\s+\\w+\\("
  "regex-dotted regex pgxpool\\.\\w+"
  "regex-anchored regex ^func\\s"
  "regex-classcount regex [0-9a-f]{8}-[0-9a-f]{4}"
  "regex-alternation regex return|continue|break"
  "regex-dense-scan regex \\w{3,8}"
  "regex-eol regex ;\$"
  "regex-litalt regex panic|0x"
)

echo "building gist + persisting the index once…"
compete_build_gist_index || exit 1
echo "building competitor indexes…"
compete_build_csearch
compete_build_zoekt

tools_raw="$(compete_tools regex)"
mapfile -t tools <<< "${tools_raw}"
echo
echo "macroscopic race — fresh-process cold query, hyperfine runs=${RUNS} (+${WARMUP} warmup)"
echo "field: gist ${tools[*]}"
echo

# One hyperfine JSON per (class, tool). A gist cell additionally takes its
# official-rg oracle and must prove an exact, order-insensitive file set first.
bench_one() { # <class> <tool> <cmd> [rg-oracle] → 0 timed, 1 rejected
  local class="$1" tool="$2" cmd="$3" oracle="${4:-}" attempt log
  [[ -z "${cmd}" || "${cmd}" = "false" ]] && return 0
  if [[ -n "${oracle}" ]]; then
    compete_precheck_equivalent "${cmd}" "${oracle}" "${class}/${tool}" || return 1
  else
    compete_precheck_status "${cmd}" "${class}/${tool}" || return 1
  fi
  log="${WORK}/${class}__${tool}.hyperfine.log"
  for attempt in 1 2; do
    rm -f "${WORK}/${class}__${tool}.json"
    if compete_hyperfine --warmup "${WARMUP}" --runs "${RUNS}" \
      --export-json "${WORK}/${class}__${tool}.json" \
      "${cmd}" > /dev/null 2> "${log}"; then
      rm -f "${log}"
      return 0
    fi
    [[ "${attempt}" = 1 ]] && echo "  transient timing failure ${class}/${tool}; retrying clean cell…" >&2
  done
  echo "  CELL FAILED during timing ${class}/${tool}: ${cmd}" >&2
  awk 'NR <= 20 { print "    " $0 }' "${log}" >&2
  return 1
}

cd "${REPO}" || exit 1
: > "${WORK}/order.tsv"
for row in "${PROBES[@]}"; do
  read -r class kind pat <<< "${row}"
  printf '%s\t%s\t%s\n' "${class}" "${kind}" "${pat}" >> "${WORK}/order.tsv"
  if [[ "${kind}" = literal ]]; then
    gcmd="$(compete_lit_cmd gist "${pat}")"
    rcmd="$(compete_lit_cmd rg "${pat}")"
  else
    gcmd="$(compete_rgx_cmd gist "${pat}")"
    rcmd="$(compete_rgx_cmd rg "${pat}")"
  fi
  # gist is the subject of the certificate: a hard failure invalidates it, so abort.
  bench_one "${class}" gist "${gcmd}" "${rcmd}" || {
    echo "certificate aborted: gist failed equivalence/status on ${class}" >&2
    exit 1
  }
  printf "  %-18s " "${class}"
  for t in "${tools[@]}"; do
    if [[ "${kind}" = literal ]]; then
      cmd="$(compete_lit_cmd "${t}" "${pat}")"
    else cmd="$(compete_rgx_cmd "${t}" "${pat}")"; fi
    # A competitor hard failure warns + excludes that cell (no set -e here), but
    # does not abort gist's certificate.
    bench_one "${class}" "${t}" "${cmd}"
  done
  echo "done"
done

# meta for the report
roots_str="${ROOTS[*]}"
cat > "${WORK}/meta.json" << EOF
{ "runs": ${RUNS}, "warmup": ${WARMUP}, "roots": "${roots_str}" }
EOF

echo
echo "computing bootstrap-CI medians + Mann-Whitney dominance (gist vs rg)…"
python3 "${HERE}/certify_stats.py" "${WORK}" \
  --certificate "${CERT}" \
  --csv "${MACRO_CSV}" \
  --order "${WORK}/order.tsv" \
  --meta "${WORK}/meta.json"

echo "macroscopic section appended to ${CERT}"

# ── reproducibility artifacts — a certificate a third party can regenerate from
# committed bytes: raw samples + the machine/tool/corpus provenance that produced
# them (check_artifacts.py enforces this set). ──
echo "emitting reproducibility metadata…"
rm -rf "${OUT}/raw"
mkdir -p "${OUT}/raw"
raw_files=("${WORK}"/*__*.json)
[[ -f "${raw_files[0]}" ]] || {
  echo "certificate aborted: no raw hyperfine cells were emitted" >&2
  exit 1
}
cp -f "${raw_files[@]}" "${OUT}/raw/"

tool_identity() { # <certificate tool id> <executable>
  local name="$1" executable="$2"
  [[ -x "${executable}" ]] || {
    echo "certificate aborted: no executable identity for ${name}" >&2
    return 1
  }
  python3 - "${name}" "${executable}" << 'PY'
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[2], "rb") as executable:
    for chunk in iter(lambda: executable.read(1 << 20), b""):
        digest.update(chunk)
print(f"{sys.argv[1]} sha256:{digest.hexdigest()}")
PY
}

zig_bin="$(command -v zig)" || exit 1
hyperfine_bin="$(command -v hyperfine)" || exit 1
{
  tool_identity gist "${GIST_BIN}" || exit 1
  tool_identity zig "${zig_bin}" || exit 1
  tool_identity hyperfine "${hyperfine_bin}" || exit 1
  for t in "${tools[@]}"; do
    executable="${t}"
    [[ "${t}" = gitgrep ]] && executable=git
    tool_bin="$(command -v "${executable}")" || exit 1
    tool_identity "${t}" "${tool_bin}" || exit 1
  done
} > "${OUT}/tool-versions.txt.tmp"
mv "${OUT}/tool-versions.txt.tmp" "${OUT}/tool-versions.txt"

python3 - "${PATHS_LIST}" "${REPO}" "${OUT}/corpus-manifest.tsv" "${OUT}/machine.json" "${RUNS}" "${WARMUP}" "${roots_str}" "${CERT_ALLOW_DIRTY:-0}" << 'PY' || exit 1
import hashlib
import json
import os
import platform
import subprocess
import sys

paths_list, repo, manifest, machine_json, runs, warmup, roots, allow_dirty = sys.argv[1:9]

# A manifest row is a promise: these exact bytes produced the timings above. On a
# clean tree any file that vanishes or moves under us breaks that promise and is
# fatal. On a coworking tree (CERT_ALLOW_DIRTY=1) ~10 agents edit continuously, so
# a churned file is expected — losing a half-hour of valid measurement to someone
# else's `rm` is not integrity, it is brittleness. Such a file is DROPPED from the
# manifest rather than hashed loosely, and counted in machine.json, so the
# certificate states exactly which bytes it can and cannot vouch for. Still
# fail-closed: past CHURN_CEILING the corpus moved too much to certify at all.
CHURN_CEILING = 0.01
churn_tolerated = allow_dirty == "1"
unstable: list[str] = []


def churned(pb: bytes, why: str) -> None:
    if not churn_tolerated:
        raise SystemExit(f"corpus file {why} while hashing: {os.fsdecode(pb)}")
    unstable.append(os.fsdecode(pb))


n = tot = 0
raw = open(paths_list, "rb").read()
manifest_tmp = manifest + ".tmp"
with open(manifest_tmp, "wb") as mf:
    mf.write(b"path\tsize_bytes\tsha256\n")
    for pb in raw.split(b"\0"):
        if not pb:
            continue
        if any(c in pb for c in (b"\t", b"\n", b"\r")):
            raise SystemExit(f"manifest cannot encode control characters in path: {pb!r}")
        path = os.path.join(os.fsencode(repo), pb)
        digest = hashlib.sha256()
        try:
            with open(path, "rb") as source:
                before = os.fstat(source.fileno())
                for chunk in iter(lambda: source.read(1 << 20), b""):
                    digest.update(chunk)
                after = os.fstat(source.fileno())
        except (FileNotFoundError, NotADirectoryError):
            churned(pb, "vanished")
            continue
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            churned(pb, "changed")
            continue
        mf.write(pb + f"\t{before.st_size}\t{digest.hexdigest()}\n".encode())
        n += 1
        tot += before.st_size
if unstable and len(unstable) > CHURN_CEILING * (n + len(unstable)):
    raise SystemExit(
        f"corpus churned past the ceiling while hashing: {len(unstable)} of "
        f"{n + len(unstable)} files (> {CHURN_CEILING:.0%}) — re-mint on a quieter tree"
    )
os.replace(manifest_tmp, manifest)

def sysctl(k):
    try:
        return subprocess.check_output(["sysctl", "-n", k], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return ""

def head():
    try:
        return subprocess.check_output(["git", "-C", repo, "rev-parse", "HEAD"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"

fs = "unknown"
try:
    if platform.system() == "Darwin":
        for ln in subprocess.check_output(["diskutil", "info", "/"], text=True).splitlines():
            if "File System Personality" in ln:
                fs = ln.split(":", 1)[1].strip()
                break
    else:
        fs = subprocess.check_output(["stat", "-f", "-c", "%T", "/"], text=True).strip()
except (OSError, subprocess.CalledProcessError):
    pass
ram_bytes = int(sysctl("hw.memsize") or 0)
if not ram_bytes:
    try:
        ram_bytes = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    except (OSError, ValueError):
        pass
machine = {
    "cpu_model": sysctl("machdep.cpu.brand_string") or platform.processor() or "unknown",
    "cpu_count": int(sysctl("hw.ncpu") or os.cpu_count() or 0),
    "ram_bytes": ram_bytes,
    "os": f"{platform.system()} {platform.release()}",
    "kernel": platform.release(),
    "filesystem": fs,
    "git_commit": head(),
    "corpus_file_count": n,
    "corpus_total_bytes": tot,
    # Count is exact; the path list is capped so one pathological run cannot bloat
    # the artifact. Both are absent on a clean-tree mint.
    "corpus_unstable_files": len(unstable),
    "corpus_unstable": sorted(unstable)[:64],
    "runs": int(runs),
    "warmup": int(warmup),
    "roots": roots,
}
if not unstable:
    del machine["corpus_unstable_files"], machine["corpus_unstable"]
with open(machine_json, "w") as output:
    output.write(json.dumps(machine, indent=2) + "\n")
print(f"  machine.json: {machine['cpu_model']} · {machine['cpu_count']} cores · corpus {n} files / {tot} B")
if unstable:
    print(f"  corpus churn: {len(unstable)} file(s) changed under the mint, excluded from the manifest")
    for p in sorted(unstable)[:5]:
        print(f"    - {p}")
PY

python3 - "${OUT}/raw" "${OUT}/command-log.txt" << 'PY' || exit 1
import json
import sys
from pathlib import Path

raw_dir, out = map(Path, sys.argv[1:3])
lines = []
for jf in sorted(raw_dir.glob("*__*.json")):
    doc = json.loads(jf.read_text())
    results = doc.get("results") or []
    if len(results) != 1 or not results[0].get("command"):
        raise SystemExit(f"raw cell lacks one exact command: {jf}")
    command = results[0]["command"]
    if "\n" in command or "\t" in command:
        raise SystemExit(f"command log cannot encode control characters: {jf}")
    lines.append(f"{jf.name}\t{command}")
out.write_text("\n".join(lines) + "\n")
print(f"  command-log.txt: {len(lines)} timed commands")
PY

python3 "${HERE}/../gates/index_size_accounting.py" \
  --index-dir "${OUT}" --csearch "${CSEARCH_IDX}" --zoekt "${ZOEKT_DIR}" || exit 1

# Layers B / B′ / C / D — automatic; never leave a header-only certificate.
echo "splicing Layers B/B′/C/D…"
CERT_OUT="${OUT}" bash "${HERE}/certify_layers.sh" || exit 1

# Warm tier — the resident-daemon regime an agent actually drives (ADR-352 rung
# 2.5). Additive: splices a marked section into CERTIFICATE.md + emits
# certify_warm.csv. Never blocks the mint (a missing daemon/rival is honestly
# reported), so the cold Layers A–E stay the reproducibility-gated headline.
echo "racing the warm tier (resident daemon)…"
RUNS="${RUNS}" WARMUP="${WARMUP}" bash "${HERE}/certify_warm.sh" \
  || echo "  warm tier skipped (daemon/rival unavailable) — cold cert unaffected" >&2

# --rank lane — the one output shape rg can't express (Layer A). Fail-closed: the
# report enforces no-fabrication + coverage + def-boost + codegen-demote + bounded
# overhead + beats-rg, and any violation aborts the mint. Needs only rg + the
# index this run already persisted, both guaranteed on a certification machine.
echo "certifying the --rank lane (fail-closed)…"
RUNS="${RUNS}" WARMUP="${WARMUP}" bash "${HERE}/certify_rank.sh" || exit 1

# Layer G — the relate face (retrieval by description length). Fail-closed on a
# retrieval-quality contract + boundary proof; not a dominance claim. Needs only
# the staged relate binary + a deterministic synthetic corpus it mints itself.
echo "certifying the relate face (Layer G, fail-closed)…"
bash "${HERE}/certify_relate.sh" || exit 1

# Structural completeness only — a bundle is judged on its bytes, never on the
# tree that produced it. Clean-START is the top gate's job; the recorded
# git_commit is provenance a human can follow, not a condition.
python3 "${HERE}/check_artifacts.py" --artifacts-dir "${OUT}" --artifacts || exit 1

# Publish a committed snapshot when asked (CERT_PUBLISH_DIR is crate-relative).
if [[ -n "${CERT_PUBLISH_DIR:-}" ]]; then
  pub="${KERNEL}/${CERT_PUBLISH_DIR}"
  rm -rf "${pub}/raw"
  mkdir -p "${pub}/raw"
  cp -f "${CERT}" "${OUT}/certify.csv" "${MACRO_CSV}" "${OUT}/machine.json" \
    "${OUT}/tool-versions.txt" "${OUT}/corpus-manifest.tsv" \
    "${OUT}/command-log.txt" "${OUT}/index-sizes.json" "${pub}/"
  # Warm-tier + rank-lane CSVs — additive side-cars (present when those lanes ran).
  [[ -f "${OUT}/certify_warm.csv" ]] && cp -f "${OUT}/certify_warm.csv" "${pub}/"
  [[ -f "${OUT}/certify_rank.csv" ]] && cp -f "${OUT}/certify_rank.csv" "${pub}/"
  [[ -f "${OUT}/relate.csv" ]] && cp -f "${OUT}/relate.csv" "${pub}/"
  # Layer B/C/D/E/F side-cars — the certificate is incomplete without them.
  for side in portcert.json portcert.csv portbound.json roofline.json lowerbound.csv crest.csv codex.csv; do
    [[ -f "${OUT}/${side}" ]] && cp -f "${OUT}/${side}" "${pub}/"
  done
  cp -f "${OUT}/raw/"*.json "${pub}/raw/" || exit 1
  echo "formatting published certificate…"
  (cd "${REPO}" && NODE_NO_WARNINGS=1 PRETTIER_EXPERIMENTAL_CLI=1 \
    pnpm -w exec prettier --write "${pub}/CERTIFICATE.md") || exit 1
  python3 "${HERE}/check_artifacts.py" --artifacts-dir "${pub}" --artifacts || exit 1
  echo "published reproducible certificate → ${pub}"
  # Log the mint. The certificate is a whole-file rewrite, so without this the
  # tree keeps no memory of what the previous one claimed or which layers it
  # carried — see bench/certify/LEDGER.md.
  python3 "${HERE}/ledger.py" record --bundle "${pub}" || exit 1
fi
