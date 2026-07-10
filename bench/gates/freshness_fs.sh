#!/usr/bin/env bash
# Freshness filesystem gate — the live-tree half of the "no false negatives" claim.
#
# `corpus/fresh_test.zig` unit-tests the `widen` set algebra; this gate exercises
# the REAL CLI against a REAL filesystem: build the index ONCE, then mutate the
# tree (add / edit / delete / rename / preserved-mtime / unreadable dir) and after
# each mutation require the index-accelerated `gist rg -l` to equal `rg -l` on the
# live tree — rg (which always reads live) is the ground truth. A miss is a
# freshness false negative; the whole point of the overlay is that one build stays
# correct as coworker agents churn the tree.
#
# `-l` is on the parallel engine's eligible surface (`pipeline.zig`), which streams
# each hit to stdout in worker-discovery order rather than buffering the whole
# walk to sort it — so `fresh()` accepts an exact match OR a match modulo line
# order (same ORDER soft pass `line_parity.sh` and `bench/rgsuite/run.py` apply);
# this gate cares about the FILE SET being right, not the order it streams in.
#
# Two classes:
#   fresh — gist (index-accelerated) MUST equal rg's file SET (order-insensitive).
#           A genuine set diff fails the gate.
#   track — a documented gap: reported loudly, does not fail the gate.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$(cd "${HERE}/../.." && pwd)"
GIST="${GIST:-${KERNEL}/zig-out/bin/gist}"
command -v rg > /dev/null || {
  echo "ripgrep (rg) not found on PATH"
  exit 1
}
if [[ ! -x "$GIST" ]]; then
  echo "building gist (ReleaseFast)…"
  (cd "$KERNEL" && zig build -Doptimize=ReleaseFast > /dev/null 2>&1) || {
    echo "gist build failed"
    exit 1
  }
fi

CORPUS="$(mktemp -d)"
REF="$(mktemp -d)"
# chmod first so the 000 subdir from the unreadable-dir case is removable.
trap 'chmod -R u+rwx "${CORPUS}" 2>/dev/null; rm -rf "${CORPUS}" "${REF}"' EXIT

mkdir -p "${CORPUS}/sub"
printf 'needle base\n' > "${CORPUS}/base.txt"     # indexed, has needle
printf 'nothing here\n' > "${CORPUS}/plain.txt"   # indexed, no needle
printf 'will change\n' > "${CORPUS}/edit.txt"     # indexed, no needle (→ edited)
printf 'needle doomed\n' > "${CORPUS}/del.txt"    # indexed, has needle (→ deleted)
printf 'needle movable\n' > "${CORPUS}/ren.txt"   # indexed, has needle (→ renamed)
printf 'append base\n' > "${CORPUS}/pm_app.txt"   # indexed, no needle (→ preserved-mtime append)
printf 'sixsix\n' > "${CORPUS}/pm_same.txt"       # indexed, no needle, 7 bytes (→ same-size swap)
printf 'needle deep\n' > "${CORPUS}/sub/deep.txt" # indexed, has needle (→ unreadable dir)

cd "${CORPUS}" || exit 1
"$GIST" index > /dev/null 2>&1 || {
  echo "gist index failed"
  exit 1
}
[[ -f .local/gist-verify/built.ns ]] || {
  echo "no freshness anchor (built.ns) after index"
  exit 1
}

fails=0
fresh() { # <label> — gist (index-accelerated) must equal rg's file set (live), order-insensitive
  local label="$1" g r
  g="$("$GIST" rg -l --sort path -e needle . 2> /dev/null | sort)"
  r="$(rg -l --sort path -e needle . 2> /dev/null | sort)"
  if [[ "$g" == "$r" ]]; then
    echo "  ok    : ${label}"
  else
    echo "  FAIL  : ${label}  (freshness divergence vs live rg)"
    diff <(printf '%s\n' "$r") <(printf '%s\n' "$g") | head -10 | sed 's/^/          /'
    fails=$((fails + 1))
  fi
}

echo "### freshness — one index build must stay correct as the tree mutates ###"
fresh "baseline (index just built)"

printf 'needle new\n' > new.txt
fresh "new file under indexed root is found"

printf 'now with needle\n' >> edit.txt
fresh "edited indexed file that gains the needle is found"

rm del.txt
fresh "deleted indexed file is not printed"

mv ren.txt ren2.txt
fresh "renamed indexed file tracked (old path gone, new path found)"

# preserved-mtime: content changes but the mtime is restored to its pre-edit value.
cp -p pm_app.txt "${REF}/pm_app.ref"
printf 'sneaky needle\n' >> pm_app.txt
touch -r "${REF}/pm_app.ref" pm_app.txt
fresh "preserved-mtime APPEND still found (gist re-verifies live bytes)"

cp -p pm_same.txt "${REF}/pm_same.ref"
printf 'needle\n' > pm_same.txt # 7 bytes == 'sixsix\n', defeats a size-only check
touch -r "${REF}/pm_same.ref" pm_same.txt
fresh "preserved-mtime SAME-SIZE overwrite still found"

echo "### walk-error signaling — an unreadable dir must be reported, never silent ###"
# Both engines discover `sub/` recursively by default (`-l` doesn't disqualify
# the parallel dispatch — see `pipeline.eligible`), so this must hold whichever
# one runs. `GIST_NO_PARALLEL` (see that function's doc comment) forces the
# serial engine for the second pass — the exact gap that let the parallel
# engine's own `processDir` swallow an EACCES `openat` in silence (fixed
# alongside `run.zig`'s `reportWalkError`; see `pipeline.zig`'s twin of it).
walk_error_case() { # <engine label>
  local engine="$1" g ge gerr re
  chmod 000 sub
  g="$("$GIST" rg -l --sort path -e needle . 2> /tmp/fresh_ge.$$)"
  ge=$?
  gerr="$(cat /tmp/fresh_ge.$$)"
  rg -l --sort path -e needle . > /dev/null 2> /tmp/fresh_re.$$
  re=$?
  rm -f /tmp/fresh_ge.$$ /tmp/fresh_re.$$
  chmod u+rwx sub
  # rg prints `rg: <path>: Permission denied (os error 13)` and exits 2; a dir the
  # walk can't descend is a POTENTIAL false negative that MUST be signaled. Was a
  # tracked CANDIDATE BUG (gist skipped it silently, exit 0) — now fixed on both
  # engines to match rg's diagnostic + exit code.
  if [[ "$gerr" == *"Permission denied"* && "$ge" == "2" && "$re" == "2" ]]; then
    echo "  ok    : unreadable dir reported [${engine}] (gist exit ${ge}, 'Permission denied' on stderr) — matches rg"
  else
    echo "  FAIL  : unreadable dir not signaled like rg [${engine}] (gist exit ${ge}, stderr=[${gerr}]; rg exit ${re})"
    fails=$((fails + 1))
  fi
}
unset GIST_NO_PARALLEL
walk_error_case "parallel/pipeline.zig"
export GIST_NO_PARALLEL=1
walk_error_case "serial/run.zig"
unset GIST_NO_PARALLEL

echo
if [[ "$fails" -eq 0 ]]; then
  echo "PASS: freshness holds — one build stays byte-correct vs live rg across add/edit/delete/rename/preserved-mtime."
else
  echo "FAIL: ${fails} freshness case(s) diverge from the live tree."
  exit 1
fi
