#!/usr/bin/env bash
# Fail-closed benchmark-wrapper contract gate.
#
# The race/certificate timers drain a command's stdout through `… | wc -l` for
# two good reasons: it forces every tool to do its FULL work (ugrep's `-l` is
# lazy and short-circuits when its output is discarded), and it neutralizes a
# needle MISS (exit 1) so a legitimate "0 files" result doesn't abort the run.
# The DANGER is that the same drain (a pipe's status is always `wc`'s 0) also
# HIDES a hard error — an unknown flag, a crash, a bad regex, a missing path
# (exit >= 2) — letting hyperfine time a fast parse failure as if it were a
# search. This gate pins the contract every timer must honor:
#
#     exit 0  -> match          (valid, timed)
#     exit 1  -> no match       (valid, timed)
#     exit >= 2 -> hard failure (the benchmark MUST surface it, never time it)
#
# `run_drained` below is that contract in one testable helper. `_compete.sh`
# (`hf_mean`) and `certify.sh` (`bench_one`) already pre-check the real exit code
# the same way (fail-closed since the honesty pass); this gate is the committed,
# standalone proof that the drain + exit-code distinction actually holds — run it
# in CI before any performance verdict is trusted.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$(cd "${HERE}/../.." && pwd)" # gates/ -> bench/ -> gist root

# Drain output (force full work + swallow the exit-1 no-match) while PRESERVING a
# hard-error exit (>= 2), so the caller can fail closed. Deliberately `bash -c`
# (not `-lc`): a login shell would drag in interactive/toolchain activation that
# has nothing to do with the timed command.
run_drained() {
  local out rc
  out="$(mktemp)"
  bash -c "$1" > "${out}" 2>&1
  rc=$?
  wc -l < "${out}" > /dev/null # uniform, microsecond drain
  rm -f "${out}"
  [[ "${rc}" -le 1 ]] && return 0
  return "${rc}"
}

fails=0
ok() { # <cmd> <label> — must be ACCEPTED (exit 0/1)
  if run_drained "$1"; then echo "  ok   (accepted) : $2"; else
    echo "  FAIL (rejected)  : $2"
    fails=$((fails + 1))
  fi
}
bad() { # <cmd> <label> — must be REJECTED (exit >= 2)
  if run_drained "$1"; then
    echo "  FAIL (accepted)  : $2"
    fails=$((fails + 1))
  else echo "  ok   (rejected)  : $2"; fi
}

echo "### fail-closed contract — pure shell ###"
ok "printf 'x\n'; exit 0" "exit 0  (match)"
ok "printf '';    exit 1" "exit 1  (no match)"
bad "printf 'x\n'; exit 2" "exit 2  (hard error masked by the drain)"
bad "exit 3" "exit 3  (hard error)"
bad "nonexistent_command_xyz_9271" "127     (command not found)"

echo "### fail-closed contract — the wired gist CLI ###"
GIST="${GIST:-${KERNEL}/zig-out/bin/gist}"
if [[ ! -x "${GIST}" ]]; then
  echo "  (building gist — ReleaseFast install step)…"
  (cd "${KERNEL}" && zig build -Doptimize=ReleaseFast > /dev/null 2>&1) || true
fi
if [[ -x "${GIST}" ]]; then
  corpus="$(mktemp -d)"
  printf 'please find me here\n' > "${corpus}/a.txt"
  ok "'${GIST}' -l -- find '${corpus}'" "gist literal, matches (exit 0)"
  ok "'${GIST}' -l -- zznomatchzz '${corpus}'" "gist literal, no match (exit 1)"
  bad "'${GIST}' '(' -l -- '${corpus}'" "gist unbalanced regex (must fail, not time a parse error)"
  bad "'${GIST}' --definitely-not-a-real-flag -- x '${corpus}'" "gist unknown flag (must fail loud)"
  rm -rf "${corpus}"
else
  echo "  (skipped: no gist binary and 'zig build' unavailable on PATH)"
fi

echo
if [[ "${fails}" -eq 0 ]]; then
  echo "PASS: fail-closed contract holds — exit 0/1 timed, exit >= 2 surfaced."
else
  echo "FAIL: ${fails} case(s) violate the fail-closed contract."
  exit 1
fi
