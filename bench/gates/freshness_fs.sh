#!/usr/bin/env bash
# Freshness filesystem gate — live-tree proof under corpus/README.md's model.
#
# The corpus has >1024 indexed files so indexSavingsWorthTable admits the path.
# `GIST_TEST_REQUIRE_ELISION=1` makes the parallel engine load synchronously and
# fail unless the real elision oracle is active; a tiny corpus/full-read fallback
# can no longer pass vacuously. Every mutation is then compared with live `rg`.
#
# `-l` is parallel-eligible and streams in discovery order, so comparisons sort
# both file sets. Unit tests pin mtime/ctime equality and unavailable-metadata
# decisions; this live gate pins add/edit/delete/rename, preserved/backdated
# mtime, same-size overwrite, an exact anchor boundary, and traversal failure.
set -uo pipefail

# Lift gist's default soft output cap so a large `-l` set can't clip the rg
# oracle comparison (the hard OOM ceiling stays on).
export GIST_UNCAP=1

HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$(cd "${HERE}/../.." && pwd)"
command -v rg > /dev/null || {
  echo "ripgrep (rg) not found on PATH"
  exit 1
}
if [[ -z "${GIST:-}" ]]; then
  GIST="${KERNEL}/zig-out/bin/gist"
  echo "building gist (ReleaseFast)…"
  (cd "${KERNEL}" && zig build -Doptimize=ReleaseFast > /dev/null 2>&1) || {
    echo "gist build failed"
    exit 1
  }
fi
[[ -x "${GIST}" ]] || {
  echo "gist binary not executable: ${GIST}"
  exit 1
}

CORPUS="$(mktemp -d)"
REF="$(mktemp -d)"
FOREIGN="$(mktemp -d)"
# chmod first so the 000 subdir from the unreadable-dir case is removable.
trap 'chmod -R u+rwx "${CORPUS}" 2>/dev/null; rm -rf "${CORPUS}" "${REF}" "${FOREIGN}"' EXIT

mkdir -p "${CORPUS}/libs/sub"
printf 'needle base\n' > "${CORPUS}/libs/base.txt"      # indexed, has needle
printf 'nothing here\n' > "${CORPUS}/libs/plain.txt"    # indexed, no needle
printf 'will change\n' > "${CORPUS}/libs/edit.txt"      # indexed, no needle (→ edited)
printf 'needle doomed\n' > "${CORPUS}/libs/del.txt"     # indexed, has needle (→ deleted)
printf 'needle movable\n' > "${CORPUS}/libs/ren.txt"    # indexed, has needle (→ renamed)
printf 'append base\n' > "${CORPUS}/libs/pm_app.txt"    # indexed, no needle (→ preserved-mtime append)
printf 'sixsix\n' > "${CORPUS}/libs/pm_same.txt"        # indexed, 7 bytes (→ same-size swap)
printf 'mtime old\n' > "${CORPUS}/libs/mtime_equal.txt" # indexed, no needle (→ mtime == anchor)
printf 'ctime old\n' > "${CORPUS}/libs/ctime_equal.txt" # indexed, no needle (→ ctime == anchor)
printf 'needle deep\n' > "${CORPUS}/libs/sub/deep.txt"  # indexed, has needle (→ unreadable dir)

# Material noise is part of the correctness fixture, not a benchmark: it forces
# the table-admission threshold and leaves >1000 known non-candidates to elide.
i=0
while [[ "${i}" -lt 1100 ]]; do
  printf 'ordinary noise %04d\n' "${i}" > "${CORPUS}/libs/noise_${i}.txt"
  i=$((i + 1))
done

# A SECOND tree the index will never describe, written BEFORE the build so every
# file here predates the anchor — the state in which a foreign anchor is most
# tempting to believe. It shares two relative paths with the corpus and inverts
# both (`base.txt` loses the needle, `plain.txt` gains one), and it has no
# `libs/sub/`, so trusting the foreign artifacts fabricates a hit, hides a real
# one, and walks into a directory that isn't here. Asserted after the live gate.
mkdir -p "${FOREIGN}/libs"
printf 'nothing at all\n' > "${FOREIGN}/libs/base.txt"
printf 'needle sneaked in\n' > "${FOREIGN}/libs/plain.txt"

cd "${CORPUS}" || exit 1
"${GIST}" index > /dev/null 2>&1 || {
  echo "gist index failed"
  exit 1
}
[[ -f .local/gist-verify/built.ns ]] || {
  echo "no freshness anchor (built.ns) after index"
  exit 1
}

fails=0
fresh() { # <label> [pattern] — required parallel index elision must equal live rg
  local label="$1" pattern="${2:-needle}" g r ge
  GIST_TEST_REQUIRE_ELISION=1 GIST_WORKERS=1 "${GIST}" rg -l --sort path -e "${pattern}" . > "${REF}/gist.raw" 2> "${REF}/gist.err"
  ge=$?
  g="$(sort "${REF}/gist.raw")"
  r="$(rg -l --sort path -e "${pattern}" . 2> /dev/null | sort)"
  if [[ "${ge}" -eq 0 && "${g}" == "${r}" ]]; then
    echo "  ok    : ${label} [forced index elision]"
  else
    echo "  FAIL  : ${label}  (exit=${ge}; $(< "${REF}/gist.err"))"
    diff <(printf '%s\n' "${r}") <(printf '%s\n' "${g}") | sed -n '1,10p' | sed 's/^/          /'
    fails=$((fails + 1))
  fi
}

fresh_serial() { # final compatibility check for run.zig's synchronous overlay
  local label="$1" g r ge
  GIST_NO_PARALLEL=1 "${GIST}" rg -l --sort path -e needle . > "${REF}/gist-serial.raw" 2> "${REF}/gist-serial.err"
  ge=$?
  g="$(sort "${REF}/gist-serial.raw")"
  r="$(rg -l --sort path -e needle . 2> /dev/null | sort)"
  if [[ "${ge}" -eq 0 && "${g}" == "${r}" ]]; then
    echo "  ok    : ${label} [serial overlay]"
  else
    echo "  FAIL  : ${label} (exit=${ge}; $(< "${REF}/gist-serial.err"))"
    fails=$((fails + 1))
  fi
}

assert_preserved_mtime_uses_ctime() { # <path>
  python3 - "$1" .local/gist-verify/built.ns << 'PY'
import os
import struct
import sys
from pathlib import Path

path = Path(sys.argv[1])
anchor = struct.unpack("<q", Path(sys.argv[2]).read_bytes()[:8])[0]
stat = path.stat()
if not stat.st_mtime_ns < anchor <= stat.st_ctime_ns:
    raise SystemExit(
        f"{path}: fixture did not isolate ctime "
        f"(mtime={stat.st_mtime_ns}, anchor={anchor}, ctime={stat.st_ctime_ns})"
    )
PY
}

echo "### freshness — one index build, real elision, live filesystem ###"
fresh "baseline (index just built)"

printf 'needle new\n' > libs/new.txt
fresh "new file under indexed root is found"

printf 'now with needle\n' >> libs/edit.txt
fresh "edited indexed file that gains the needle is found"

rm libs/del.txt
fresh "deleted indexed file is not printed"

mv libs/ren.txt libs/ren2.txt
fresh "renamed indexed file tracked (old path gone, new path found)"

# Preserved mtime: each assertion proves mtime is still pre-anchor while ctime is
# post-anchor. Passing therefore exercises the new ctime leg, not mtime or size.
cp -p libs/pm_app.txt "${REF}/pm_app.ref"
printf 'sneaky needle\n' >> libs/pm_app.txt
touch -r "${REF}/pm_app.ref" libs/pm_app.txt
assert_preserved_mtime_uses_ctime libs/pm_app.txt || exit 1
fresh "preserved-mtime APPEND is found via ctime"

cp -p libs/pm_same.txt "${REF}/pm_same.ref"
printf 'needle\n' > libs/pm_same.txt # 7 bytes == 'sixsix\n', defeats size checks
touch -r "${REF}/pm_same.ref" libs/pm_same.txt
assert_preserved_mtime_uses_ctime libs/pm_same.txt || exit 1
fresh "preserved-mtime SAME-SIZE overwrite is found via ctime"

# Exact mtime boundary: setting mtime to built.ns must remain live (`>=`, not
# `>`). The ctime equality leg is isolated next by temporarily setting the
# anchor to the file's unforgeable post-write ctime.
printf 'mtime_boundary_token\n' > libs/mtime_equal.txt
python3 - libs/mtime_equal.txt .local/gist-verify/built.ns << 'PY'
import os
import struct
import sys
from pathlib import Path

path = Path(sys.argv[1])
anchor = struct.unpack("<q", Path(sys.argv[2]).read_bytes()[:8])[0]
stat = path.stat()
os.utime(path, ns=(stat.st_atime_ns, anchor))
if path.stat().st_mtime_ns != anchor:
    raise SystemExit("filesystem cannot represent the exact anchor tick")
PY
fresh "mtime == anchor is conservatively live" mtime_boundary_token

cp .local/gist-verify/built.ns "${REF}/built.ns"
cp -p libs/ctime_equal.txt "${REF}/ctime_equal.ref"
printf 'ctime_boundary_token\n' > libs/ctime_equal.txt
touch -r "${REF}/ctime_equal.ref" libs/ctime_equal.txt
python3 - libs/ctime_equal.txt .local/gist-verify/built.ns << 'PY'
import os
import struct
import sys
from pathlib import Path

path = Path(sys.argv[1])
anchor_path = Path(sys.argv[2])
stat = path.stat()
if not stat.st_mtime_ns < stat.st_ctime_ns:
    raise SystemExit("fixture did not preserve an older mtime")
anchor_path.write_bytes(struct.pack("<q", stat.st_ctime_ns))
PY
fresh "ctime == anchor is conservatively live" ctime_boundary_token
cp "${REF}/built.ns" .local/gist-verify/built.ns

fresh_serial "serial fresh.candidates remains compatible"

echo "### walk-error signaling — an unreadable dir must be reported, never silent ###"
# Both engines discover `sub/` recursively by default (`-l` doesn't disqualify
# the parallel dispatch — see `pipeline.eligible`), so this must hold whichever
# one runs. `GIST_NO_PARALLEL` (see that function's doc comment) forces the
# serial engine for the second pass — the exact gap that let the parallel
# engine's own `processDir` swallow an EACCES `openat` in silence (fixed
# alongside `run.zig`'s `reportWalkError`; see `pipeline.zig`'s twin of it).
walk_error_case() { # <engine label>
  local engine="$1" ge gerr re
  chmod 000 libs/sub
  if [[ "${engine}" == parallel* ]]; then
    GIST_TEST_REQUIRE_ELISION=1 GIST_WORKERS=1 "${GIST}" rg -l --sort path -e needle . > "${REF}/fresh_gout" 2> "${REF}/fresh_ge"
  else
    GIST_NO_PARALLEL=1 "${GIST}" rg -l --sort path -e needle . > "${REF}/fresh_gout" 2> "${REF}/fresh_ge"
  fi
  ge=$?
  gerr="$(< "${REF}/fresh_ge")"
  rg -l --sort path -e needle . > /dev/null 2> "${REF}/fresh_re"
  re=$?
  chmod u+rwx libs/sub
  # rg prints `rg: <path>: Permission denied (os error 13)` and exits 2; a dir the
  # walk can't descend is a POTENTIAL false negative that MUST be signaled. Was a
  # tracked CANDIDATE BUG (gist skipped it silently, exit 0) — now fixed on both
  # engines to match rg's diagnostic + exit code.
  if [[ "${gerr}" == *"Permission denied"* && "${ge}" == "2" && "${re}" == "2" ]]; then
    echo "  ok    : unreadable dir reported [${engine}] (gist exit ${ge}, 'Permission denied' on stderr) — matches rg"
  else
    echo "  FAIL  : unreadable dir not signaled like rg [${engine}] (gist exit ${ge}, stderr=[${gerr}]; rg exit ${re})"
    fails=$((fails + 1))
  fi
}
walk_error_case "parallel/pipeline.zig"
walk_error_case "serial/run.zig"

echo "### foreign artifacts — a directory built over ANOTHER tree accelerates nothing ###"
# Every persisted accelerator names files RELATIVE to its build directory and
# dates them against that build's anchor, so aiming GIST_DIR at another
# checkout is not a stale index — it is a confident one about the wrong tree.
# The whole surface must decline (`corpus/index/frame/frame.zig`) and answer
# live: the content shard must not serve the corpus's `base.txt` bytes, the
# anchor must not "prove" `plain.txt` unchanged and elide the real hit, and the
# phantom walk must not descend a `libs/sub/` that exists only over there.
ART="${CORPUS}/.local/gist-verify"
foreign_out="$(cd "${FOREIGN}" && GIST_DIR="${ART}" "${GIST}" rg -l --sort path -e needle . 2> "${REF}/foreign.err")"
foreign_exit=$?
foreign_ref="$(cd "${FOREIGN}" && rg -l --sort path -e needle . 2> /dev/null)"
foreign_err="$(< "${REF}/foreign.err")"
if [[ "${foreign_exit}" -eq 0 && "${foreign_out}" == "${foreign_ref}" && "${foreign_err}" != *"No such file or directory"* ]]; then
  echo "  ok    : foreign GIST_DIR answers live and equals rg (${foreign_ref})"
else
  echo "  FAIL  : foreign GIST_DIR diverges (exit=${foreign_exit}, stderr=[${foreign_err}])"
  diff <(printf '%s\n' "${foreign_ref}") <(printf '%s\n' "${foreign_out}") | sed -n '1,10p' | sed 's/^/          /'
  fails=$((fails + 1))
fi

# Right answers alone leave the caller wondering why nothing is ever warm, so
# status must NAME the tree these artifacts do describe.
foreign_status="$(cd "${FOREIGN}" && GIST_DIR="${ART}" "${GIST}" status 2>&1)"
if [[ "${foreign_status}" == *"built over"* && "${foreign_status}" == *"not this tree"* ]]; then
  echo "  ok    : status names the other tree instead of reporting a healthy index"
else
  echo "  FAIL  : status hides the foreign binding: [${foreign_status}]"
  fails=$((fails + 1))
fi

# The same confusion reaches the RESIDENT tier, where it would be silent: the
# socket lives in the artifact directory too, so a shared GIST_DIR aims both
# trees at one rendezvous, and a warm answer carries no path prefix to give the
# mix-up away. The daemon records its tree beside its socket and the client
# re-proves it before dialing (`corpus/index/frame/frame.zig`).
"${GIST}" serve > /dev/null 2>&1 &
daemon_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -S "${ART}/gistd.sock" ]] && break
  sleep 0.3
done
here_trace="$(GIST_TRACE=warm "${GIST}" needle -l 2>&1)"
if [[ "${here_trace}" == *"[warm]"* ]]; then
  here_set="$(printf '%s\n' "${here_trace}" | grep -v '^gist: \[' | sort)"
  here_ref="$(rg -l needle | sort)"
  there_set="$(cd "${FOREIGN}" && GIST_DIR="${ART}" "${GIST}" needle -l 2> /dev/null | sort)"
  there_ref="$(cd "${FOREIGN}" && rg -l needle | sort)"
  if [[ "${here_set}" == "${here_ref}" && "${there_set}" == "${there_ref}" ]]; then
    echo "  ok    : the resident daemon stays warm for its own tree and declines the other one"
  else
    echo "  FAIL  : resident rendezvous crossed trees"
    diff <(printf '%s\n' "${there_ref}") <(printf '%s\n' "${there_set}") | sed -n '1,10p' | sed 's/^/          /'
    fails=$((fails + 1))
  fi
else
  echo "  (skipped: no daemon went warm here; the cold cases above still ran)"
fi
kill "${daemon_pid}" 2> /dev/null
wait "${daemon_pid}" 2> /dev/null

# …and indexing here must HEAL it: the amend path cannot fold into artifacts it
# cannot prove are ours, so it falls back to a full build and rebinds.
(cd "${FOREIGN}" && GIST_DIR="${ART}" "${GIST}" index > /dev/null 2>&1)
healed="$(cd "${FOREIGN}" && GIST_DIR="${ART}" "${GIST}" status 2>&1)"
if [[ "${healed}" != *"built over"* && "${healed}" == *"freshness anchor set"* ]]; then
  echo "  ok    : \`gist index\` rebinds the directory to this tree"
else
  echo "  FAIL  : indexing did not rebind: [${healed}]"
  fails=$((fails + 1))
fi

echo
if [[ "${fails}" -eq 0 ]]; then
  echo "PASS: freshness matches live rg with forced elision across metadata boundaries and tree mutations."
else
  echo "FAIL: ${fails} freshness case(s) diverge from the live tree."
  exit 1
fi
