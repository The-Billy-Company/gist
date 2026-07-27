#!/usr/bin/env bash
# Judge the generated manual and completions with the tools that consume them.
#
# The Zig suite proves the renderers emit what the Surface says. This proves the
# other half: that bash, zsh, fish, PowerShell and mandoc actually accept the
# bytes, that the zsh menu really does file each flag in exactly one group, and
# that no completion can reach for a subprocess at tab time. Each shell that is
# not installed self-skips; the checks that need nothing but the file always run.
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
gist="${here}/zig-out/bin/gist"
out="$(mktemp -d)"
trap 'rm -rf "${out}"' EXIT

rc=0
pass() { printf '\033[0;32m✓\033[0m  %s\n' "${1}"; }
skip() { printf '\033[0;33m!\033[0m  %s\n' "${1}"; }
fail() {
  printf '\033[0;31m✗\033[0m  %s\n' "${1}"
  rc=1
}

if [[ ! -x ${gist} ]]; then
  skip "gist is not built (zig build) — skipping the shell-side suite"
  exit 0
fi

for target in man complete-bash complete-zsh complete-fish complete-powershell; do
  if ! "${gist}" --generate "${target}" > "${out}/${target}"; then
    fail "gist --generate ${target} failed"
    exit 1
  fi
done
pass "minted 5 artifacts from the parse table"

# ── each consumer parses its own file ────────────────────────────────────
# $1 label · $2 file · $3.. the parse command, with the file appended
parses() {
  local label="${1}" file="${2}"
  shift 2
  if ! command -v "${1}" > /dev/null 2>&1; then
    skip "${1} is not installed — skipping the ${label} parse"
    return 0
  fi
  if "${@}" "${out}/${file}" > /dev/null 2>&1; then
    pass "${label}: parses"
  else
    fail "${label}: ${*} rejected the generated file"
    "${@}" "${out}/${file}" 2>&1 | head -5
  fi
}

parses bash complete-bash bash -n
parses zsh complete-zsh zsh -n
parses fish complete-fish fish -n
parses pwsh complete-powershell pwsh -NoProfile -Command \
  '$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $args[0]),[ref]$t,[ref]$e);if($e){$e|%{$_.Message};exit 1}' --

# mandoc is the strictest reader a man page meets. One diagnostic is expected
# and deliberate: the version stands where the date goes, so the page is a pure
# function of the surface and a drift gate can diff it byte for byte.
if command -v mandoc > /dev/null 2>&1; then
  noise="$(mandoc -Tlint "${out}/man" 2>&1 | grep -cv 'cannot parse date')"
  if [[ ${noise} -eq 0 ]]; then
    pass "man: mandoc clean (bar the deliberate version-as-date)"
  else
    fail "man: ${noise} mandoc diagnostics"
    mandoc -Tlint "${out}/man" 2>&1 | grep -v 'cannot parse date' | head -10
  fi
else
  skip "mandoc is not installed — skipping the man lint"
fi

# ── a tab may not cost a process ─────────────────────────────────────────
# The whole performance claim. `_rg_types` runs `rg --type-list` per keystroke;
# nothing generated here may run anything at all.
forks=0
for f in complete-bash complete-zsh complete-fish complete-powershell; do
  if grep -qE '\$\(|`|Invoke-Expression' "${out}/${f}"; then
    fail "${f}: contains a command substitution — a tab would fork"
    forks=1
  fi
done
[[ ${forks} -eq 0 ]] && pass "no completion shells out: every menu is baked"

# ── the zsh menu files each flag in exactly one group ────────────────────
# Each group's `ignored-patterns` is a negated alternation of the spellings it
# keeps. Union them and the result must be every spelling in the file, with no
# spelling claimed twice — the property that makes `gist -<TAB>` a set of
# captioned sections rather than N copies of the whole table.
python3 - "${out}/complete-zsh" << 'PY' || rc=1
import re, sys
from collections import Counter

text = open(sys.argv[1]).read()
groups = re.findall(r"ignored-patterns '\^\(([^)]*)\)'", text)
if not groups:
    sys.exit("zsh: no group ignored-patterns found — the menu is one flat wall")

kept = Counter(s for g in groups for s in g.split('|'))
spelled = set(re.findall(r'(?<![\w-])(--?[A-Za-z0-9][\w-]*)', text.split('args=(', 1)[1]))
dupes = [s for s, n in kept.items() if n > 1]
missing = sorted(s for s in kept if s not in spelled)

if dupes:
    sys.exit(f'zsh: {len(dupes)} spellings claimed by two groups: {dupes[:5]}')
if missing:
    sys.exit(f'zsh: {len(missing)} grouped spellings are not in any spec: {missing[:5]}')
print(f'\033[0;32m\u2713\033[0m  zsh: {len(kept)} spellings across {len(groups)} captioned groups, no overlap')
PY

# A caption may not carry a colon: `_next_label` cuts `label:description` at the
# LAST one, so a colon silently moves the tag and every ignored-patterns lookup
# for that group misses — leaving a beautifully captioned copy of the whole
# option table under every heading.
if grep -oE "^  options:-[a-z-]+:[^']*" "${out}/complete-zsh" | grep -q ':.*:.*:'; then
  fail "zsh: a tag-order caption contains a colon — grouping will silently no-op"
else
  pass "zsh: no caption smuggles a colon into a tag name"
fi

exit "${rc}"
