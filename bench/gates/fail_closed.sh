#!/usr/bin/env bash
# Fail-closed benchmark-wrapper contract gate.
#
# Race/certificate timers must force complete output (ugrep's `-l` short-circuits
# when a harness sends stdout straight to /dev/null) without masking status.
# `compete_hyperfine` uses hyperfine's own `--output=pipe` sink and ignores ONLY
# rg's no-match exit 1. An unknown flag, crash, bad regex, or unreadable path
# (exit >= 2) therefore aborts the cell. This gate pins that contract:
#
#     exit 0  -> match          (valid, timed)
#     exit 1  -> no match       (valid, timed)
#     exit >= 2 -> hard failure (the benchmark MUST surface it, never time it)
#
# `run_drained` pins the pure exit contract. The sourced production helper also
# proves each gist cell file-set-equivalent to official rg before timing, and its
# real hyperfine configuration is exercised when that tool is installed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$(cd "${HERE}/../.." && pwd)" # gates/ -> bench/ -> gist root
# shellcheck source=../races/_compete.sh
source "${HERE}/../races/_compete.sh"

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

equiv_ok() { # <candidate> <oracle> <label>
  if compete_precheck_equivalent "$1" "$2" "$3" 2> /dev/null; then
    echo "  ok   (accepted) : $3"
  else
    echo "  FAIL (rejected)  : $3"
    fails=$((fails + 1))
  fi
}
equiv_bad() { # <candidate> <oracle> <label>
  if compete_precheck_equivalent "$1" "$2" "$3" 2> /dev/null; then
    echo "  FAIL (accepted)  : $3"
    fails=$((fails + 1))
  else
    echo "  ok   (rejected)  : $3"
  fi
}

echo "### semantic precheck — deterministic file sets ###"
equiv_ok "printf 'b\na\n'" "printf 'a\nb\n'" "same set in different order"
equiv_bad "printf 'a\nwrong\n'" "printf 'a\nright\n'" "semantic mismatch"
equiv_bad "printf 'a\n'; exit 2" "printf 'a\n'" "candidate hard error"
equiv_bad "printf 'a\n'" "printf 'a\n'; exit 2" "oracle hard error"

echo "### hyperfine sink — only no-match exit 1 is ignorable ###"
if have hyperfine; then
  if compete_hyperfine --warmup 0 --runs 1 "exit 1" > /dev/null 2>&1; then
    echo "  ok   (accepted) : timed no-match exit 1"
  else
    echo "  FAIL (rejected)  : timed no-match exit 1"
    fails=$((fails + 1))
  fi
  if compete_hyperfine --warmup 0 --runs 1 "exit 2" > /dev/null 2>&1; then
    echo "  FAIL (accepted)  : timed hard error exit 2"
    fails=$((fails + 1))
  else
    echo "  ok   (rejected)  : timed hard error exit 2"
  fi
else
  echo "  (skipped: hyperfine unavailable; pure precheck contract still ran)"
fi

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
  equiv_ok "'${GIST}' find -F -l -- '${corpus}'" "rg -F -l -- find '${corpus}'" "wired gist file set equals rg"
  equiv_bad "'${GIST}' find -F -l -- '${corpus}'" "rg -F -l -- absent '${corpus}'" "wired semantic mismatch"
  equiv_bad "'${GIST}' '(' -l -- '${corpus}'" "rg -F -l -- find '${corpus}'" "wired hard error"
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
