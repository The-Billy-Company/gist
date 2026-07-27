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

# mandoc reads the section out of the filename, so the page is written under
# the name it installs as rather than under its target's.
for target in man complete-bash complete-zsh complete-fish complete-powershell; do
  name="${target}"
  [[ ${target} == man ]] && name='gist.1'
  if ! "${gist}" --generate "${target}" > "${out}/${name}"; then
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
# shellcheck disable=SC2016  # PowerShell's own $-variables, not the shell's
parses pwsh complete-powershell pwsh -NoProfile -Command \
  '$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $args[0]),[ref]$t,[ref]$e);if($e){$e|%{$_.Message};exit 1}' --

# mandoc is the strictest reader a man page meets, and the bar here is silence.
if command -v mandoc > /dev/null 2>&1; then
  noise="$(mandoc -Tlint "${out}/gist.1" 2>&1 | grep -c .)"
  if [[ ${noise} -eq 0 ]]; then
    pass "man: mandoc clean"
  else
    fail "man: ${noise} mandoc diagnostics"
    mandoc -Tlint "${out}/gist.1" 2>&1 | head -10
  fi
else
  skip "mandoc is not installed — skipping the man lint"
fi

# The manual must be a pure function of (surface, version, date), so a packager
# or a drift gate that pins SOURCE_DATE_EPOCH gets identical bytes every time.
a="$(SOURCE_DATE_EPOCH=1700000000 "${gist}" --generate man | shasum)"
b="$(SOURCE_DATE_EPOCH=1700000000 "${gist}" --generate man | shasum)"
c="$(SOURCE_DATE_EPOCH=1800000000 "${gist}" --generate man | shasum)"
if [[ ${a} == "${b}" && ${a} != "${c}" ]]; then
  pass "man: reproducible under SOURCE_DATE_EPOCH, and the date is really in it"
else
  fail "man: SOURCE_DATE_EPOCH did not pin the output (or was ignored entirely)"
fi

# ── a tab may not cost a process ─────────────────────────────────────────
# The whole performance claim. `_rg_types` answers `-t<TAB>` by running
# `rg --type-list` and re-parsing it, per keystroke. Nothing generated here may
# run a program: the only substitution allowed is bash's `compgen -f/-d/-c`
# builtin, which is how a real filesystem value gets completed and is not a
# menu we could have baked. Comments are exempt — they quote the command that
# regenerates the file.
forks=0
for f in complete-bash complete-zsh complete-fish complete-powershell; do
  offenders="$(grep -vE '^\s*#' "${out}/${f}" | grep -oE '\$\([^)]*|`|Invoke-Expression' | grep -vE '^\$\(compgen -[fdc]' || true)"
  if [[ -n ${offenders} ]]; then
    fail "${f}: runs something at tab time — ${offenders//$'\n'/ }"
    forks=1
  fi
done
[[ ${forks} -eq 0 ]] && pass "no completion runs a program: every menu is baked"

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

# A value tag must be named before the option groups. zsh offers the earliest
# tag-order entry that yields anything, and at `-t<TAB>` both "finish the glued
# value" and "keep naming options" yield — so with the groups first, `gist -t`
# answers with the flag wall and `gist -t ` answers with file types. Same
# keystrokes, two different menus, no error either way.
order="$(sed -n "/tag-order '/,/^'/p" "${out}/complete-zsh")"
# `grep -n` numbers every hit; trimming at the first colon of the whole result
# takes the first one, which is the only one this cares about.
at_group="$(grep -n 'options:-' <<< "${order}" || true)"
at_value="$(grep -n ' type' <<< "${order}" || true)"
if [[ -n ${at_value} && ${at_group%%:*} -gt ${at_value%%:*} ]]; then
  pass "zsh: value tags outrank the option groups (a half-typed -t completes a type)"
else
  fail "zsh: the option groups precede the value tags — '-t<TAB>' will show flags"
fi

# ── a verb is argv[1] or it is the pattern ───────────────────────────────
# `gist -w index` searches for "index"; it does not run the index verb. Each
# shell has to say so in its own dialect, and fish's usual `__fish_use_subcommand`
# is the git rule (skip leading flags), which is precisely wrong here.
verbs=0
grep -q '(( COMP_CWORD == 1 ))' "${out}/complete-bash" || {
  fail "bash: verbs are not pinned to argv[1]"
  verbs=1
}
grep -q '__fish_is_first_arg' "${out}/complete-fish" || {
  fail "fish: verbs are not pinned to argv[1]"
  verbs=1
}
grep -q '__fish_use_subcommand' "${out}/complete-fish" && {
  fail "fish: __fish_use_subcommand skips leading flags — it will offer a verb after -w"
  verbs=1
}
# shellcheck disable=SC2016  # PowerShell's own $-variable, not the shell's
grep -q 'if ($typed -eq 1)' "${out}/complete-powershell" || {
  fail "pwsh: verbs are not pinned to argv[1]"
  verbs=1
}
[[ ${verbs} -eq 0 ]] && pass "every shell offers a verb at argv[1] and nowhere else"

# A short flag may carry its value glued on (`-tzig`), which bash hands over as
# one word. Without the split, `-t<TAB>` dead-ends — which is what ripgrep's
# generated bash does.
if grep -q 'cur == -\[!-\]\*' "${out}/complete-bash"; then
  pass "bash: a glued short value is split before the flag-list fallback"
else
  fail "bash: no glued-short-value arm — '-t<TAB>' will dead-end"
fi

exit "${rc}"
