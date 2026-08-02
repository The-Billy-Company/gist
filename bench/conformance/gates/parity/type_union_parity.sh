#!/usr/bin/env bash
# `-t` selection parity — every type named on the line is in the answer.
#
# `-t` is a UNION. `-t go -t py` means "go files or py files", and ripgrep is the
# oracle for that: it collects every `-t` into one type matcher, whatever each
# name resolves to. `-g` is a different, INTERSECTING dimension — a `-g` glob
# narrows whatever the types already chose.
#
# The bug this gate is the permanent guard for kept those two dimensions apart
# for built-in names and merged them for custom ones. A `--type-add` name
# selected with `-t` landed in the `-g` include set instead of the type set, so
# `admits()` ANDead it against the built-ins beside it:
#
#   gist --type-add 'tsx:*.tsx' -t go -t tsx   →  453 files, every one .tsx
#   rg   --type-add 'tsx:*.tsx' -t go -t tsx   →  1082 files: 629 .go + 453 .tsx
#
# One custom type silently voided every built-in type beside it. Nothing errored
# and no flag was rejected — the answer was just quietly a subset, which is the
# failure mode a search tool may never have. It survived because each half was
# individually right: built-ins union with built-ins, and a custom type alone
# matches rg exactly. Only the MIX diverges, so a gate has to ask for the mix.
#
# What is checked, per case, against rg over the same tree:
#
#   EQUALITY     gist's file set == rg's, byte for byte
#   UNION        the mixed selection ⊇ each of its parts, and is bigger than both
#   NEGATION     `-T <custom>` removes exactly what `-t <custom>` selected
#   NOT-A-GLOB   a custom `-t` does not un-ignore a gitignored file (only `-g` may)
#
# Non-vacuity floors, because equality is trivially true of two empty sets:
#   * every part of every union must claim files of its own;
#   * the union must be strictly larger than its largest part, or the case is not
#     actually testing a union.
#
# Usage: bench/conformance/gates/parity/type_union_parity.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../apparatus/roots.sh
source "${HERE}/../../../apparatus/roots.sh"
gist_resolve_roots "${HERE}" || exit 1

echo "building gist (ReleaseFast)…"
(cd "${PRODUCT}" && zig build -Doptimize=ReleaseFast > /dev/null 2>&1) || {
  echo "FAILED: build error in ${PRODUCT}" >&2
  exit 1
}
GIST="${PRODUCT}/zig-out/bin/gist"
[[ -x "${GIST}" ]] || {
  echo "FAILED: missing ${GIST}" >&2
  exit 1
}
command -v rg > /dev/null || {
  echo "FAILED: ripgrep (rg) not found on PATH — this gate has no oracle without it" >&2
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A truncated list is a wrong list, and every check here is a set comparison.
export GIST_UNCAP=1
# Never let a persisted charter or one reader's preferences decide what the
# corpus is while a gate is judging a selection over it.
export GIST_NO_CONFIG=1

# ── a corpus this gate owns ─────────────────────────────────────────────────
# The cases below need one tree that holds go, py, rust, ts AND tsx files, plus a
# gitignored one. No checkout is guaranteed to have that mix — gist's own is pure
# Zig, and the answer would silently become vacuous wherever a language is
# missing. So the corpus is synthesized here: every case is then the same case on
# every machine, and the non-vacuity floors below mean something.
REPO="${WORK}/corpus"
mkdir -p "${REPO}/src" "${REPO}/web" "${REPO}/vendor"
for f in src/handler.go src/util.go src/serve.py src/model.py src/lib.rs \
  web/api.ts web/App.tsx web/Panel.tsx; do
  printf 'let action = "run";\n' > "${REPO}/${f}"
done
# A file that matches the needle and the custom type, but is gitignored: `-t` may
# un-hide, never un-ignore, so this one must stay out of every answer below.
printf 'let action = "run";\n' > "${REPO}/vendor/Ignored.tsx"
printf 'vendor/\n' > "${REPO}/.gitignore"
# rg (and gist) apply .gitignore only inside a repository, so the ignore case has
# no subject without one.
(cd "${REPO}" && git init -q . && git add -A 2> /dev/null) || {
  echo "FAILED: could not create the synthetic corpus repo" >&2
  exit 1
}

fails=0
note() { printf "  %-6s %-34s %s\n" "$1" "$2" "${3-}"; }
count() { wc -l < "$1" | tr -d ' '; }

# One `-l` file set, sorted, into $1. $2 is the tool; the rest are its flags.
setof() {
  local dst="$1" tool="$2"
  shift 2
  (cd "${REPO}" && "${tool}" -l "$@" < /dev/null 2> /dev/null) | LC_ALL=C sort -u > "${dst}"
}

# gist and rg answer the same question, and the answer is not empty.
same() {
  local label="$1"
  shift
  setof "${WORK}/g" "${GIST}" "$@"
  setof "${WORK}/r" "rg" "$@"
  local n
  n="$(count "${WORK}/g")"
  if ! cmp -s "${WORK}/g" "${WORK}/r"; then
    note FAIL "${label}" "gist $(count "${WORK}/g") files, rg $(count "${WORK}/r")"
    diff "${WORK}/g" "${WORK}/r" | head -4 | sed 's/^/          /'
    fails=$((fails + 1))
    return 1
  fi
  if [[ "${n}" -eq 0 ]]; then
    note FAIL "${label}" "both agreed on ZERO files — a vacuous case proves nothing"
    fails=$((fails + 1))
    return 1
  fi
  note ok "${label}" "${n} files"
  return 0
}

NEEDLE='action'

echo
echo "a selection is the union of every -t on the line (rg is the oracle)"

# ── built-in ∪ built-in ─────────────────────────────────────────────────────
same "-t go"                       "${NEEDLE}" -t go
same "-t py"                       "${NEEDLE}" -t py
same "-t go -t py"                 "${NEEDLE}" -t go -t py

# ── the mix that regressed: custom ∪ built-in ───────────────────────────────
TA=(--type-add 'tsx:*.tsx')
same "-t tsx (custom, alone)"      "${NEEDLE}" "${TA[@]}" -t tsx
same "-t go -t tsx (custom+built)" "${NEEDLE}" "${TA[@]}" -t go -t tsx
same "5 types, custom last"        "${NEEDLE}" "${TA[@]}" -t go -t py -t rust -t ts -t tsx
same "5 types, custom first"       "${NEEDLE}" "${TA[@]}" -t tsx -t go -t py -t rust -t ts

# ── UNION shape — the mixed answer contains each part and exceeds both ──────
# Equality with rg would still hold if BOTH tools were wrong in the same way, so
# the union is also checked structurally, against gist's own single-type answers.
echo
echo "the mixed answer contains each part it was built from"
setof "${WORK}/only_go" "${GIST}" "${NEEDLE}" -t go
setof "${WORK}/only_tsx" "${GIST}" "${TA[@]}" "${NEEDLE}" -t tsx
setof "${WORK}/mixed" "${GIST}" "${TA[@]}" "${NEEDLE}" -t go -t tsx
n_go="$(count "${WORK}/only_go")"
n_tsx="$(count "${WORK}/only_tsx")"
n_mix="$(count "${WORK}/mixed")"
if [[ "${n_go}" -eq 0 || "${n_tsx}" -eq 0 ]]; then
  note FAIL "non-vacuous parts" "go=${n_go} tsx=${n_tsx} — a part with no files cannot prove a union"
  fails=$((fails + 1))
else
  for part in only_go only_tsx; do
    comm -23 "${WORK}/${part}" "${WORK}/mixed" > "${WORK}/lost"
    if [[ -s "${WORK}/lost" ]]; then
      note FAIL "union ⊇ ${part}" "$(count "${WORK}/lost") file(s) dropped by adding the other type"
      head -3 "${WORK}/lost" | sed 's/^/          /'
      fails=$((fails + 1))
    else
      note ok "union ⊇ ${part}" "$(count "${WORK}/${part}") files kept"
    fi
  done
  if [[ "${n_mix}" -le "${n_go}" || "${n_mix}" -le "${n_tsx}" ]]; then
    note FAIL "union is a union" "mixed=${n_mix} is not larger than go=${n_go} and tsx=${n_tsx}"
    fails=$((fails + 1))
  else
    note ok "union is a union" "${n_go} + ${n_tsx} → ${n_mix}"
  fi
fi

# ── NEGATION — `-T custom` subtracts exactly what `-t custom` selected ──────
echo
echo "-T removes exactly what -t selected"
same "-T tsx (custom)"             "${NEEDLE}" "${TA[@]}" -T tsx
setof "${WORK}/all" "${GIST}" "${NEEDLE}"
setof "${WORK}/neg" "${GIST}" "${TA[@]}" "${NEEDLE}" -T tsx
comm -23 "${WORK}/all" "${WORK}/only_tsx" > "${WORK}/expect_neg"
if cmp -s "${WORK}/expect_neg" "${WORK}/neg"; then
  note ok "-T tsx == all − (-t tsx)" "$(count "${WORK}/neg") files"
else
  note FAIL "-T tsx == all − (-t tsx)" "the negation is not the positive's complement"
  diff "${WORK}/expect_neg" "${WORK}/neg" | head -4 | sed 's/^/          /'
  fails=$((fails + 1))
fi

# ── NOT-A-GLOB — a custom `-t` is a type, so it must not un-ignore ──────────
# rg's rule: `-t` may surface a HIDDEN file, never a gitignored one; only `-g`
# un-ignores. Routing custom types through the `-g` include set broke that too,
# so the fix is only complete if a custom `-t` still respects .gitignore.
echo
echo "a custom -t is a type, not a -g glob: it must not un-ignore"
IGNORED="vendor/Ignored.tsx"
setof "${WORK}/ign" "${GIST}" "${TA[@]}" "${NEEDLE}" -t tsx
if grep -qF "${IGNORED}" "${WORK}/ign"; then
  note FAIL "un-ignore" "a custom -t surfaced the gitignored ${IGNORED}"
  fails=$((fails + 1))
else
  note ok "un-ignore" "${IGNORED} stayed ignored"
fi
# The floor for that check: it only means something if the file is really there
# and really matches — otherwise "absent from the answer" is free.
setof "${WORK}/unign" "${GIST}" "${TA[@]}" "${NEEDLE}" -t tsx --no-ignore
if grep -qF "${IGNORED}" "${WORK}/unign"; then
  note ok "un-ignore floor" "--no-ignore does surface it, so the check had a subject"
else
  note FAIL "un-ignore floor" "${IGNORED} is invisible even to --no-ignore"
  fails=$((fails + 1))
fi

echo
if [[ "${fails}" -eq 0 ]]; then
  echo "PROVEN: over this tree, every -t on the line contributes to the answer —"
  echo "        built-in or --type-add, in any order — and gist's file set is"
  echo "        byte-identical to ripgrep's for each mix. -T subtracts exactly"
  echo "        its positive, and a custom type still respects .gitignore."
else
  echo "FAILED: ${fails} invariant(s) broken. A -t that does not reach the answer"
  echo "        is a silently smaller result set, not an error — fix the argv"
  echo "        routing (Builder.addType) or the filter, never this gate."
  exit 1
fi
