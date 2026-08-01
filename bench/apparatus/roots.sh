#!/usr/bin/env bash
# Climb-don't-count resolvers for the post-split layout.
#
# Source from a bench script after setting HERE to that script's directory:
#   # shellcheck source=../apparatus/roots.sh
#   source "${HERE}/../../apparatus/roots.sh"   # adjust depth
#   gist_resolve_roots "${HERE}"
#
# Exports:
#   KERNEL      — package root (build.zig.zon), climbed from HERE
#   REPO        — corpus envelope (GIST_CORPUS_ROOT, else monorepo/billy, else KERNEL)
#   PRODUCT     — checkout that owns the gist binary (sibling gist, else KERNEL)
#   KINSHIP     — checkout that owns the relate binary (sibling relate, else PRODUCT)
#   GIST_VERIFY — GIST_DIR or ${REPO}/.local/gist-verify (artifact home)

_gist_climb_pkg() {
  local d="$1"
  while [[ -n "$d" && "$d" != / ]]; do
    if [[ -f "${d}/build.zig.zon" ]]; then
      printf '%s\n' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  return 1
}

_gist_corpus_root() {
  local pkg="$1"
  if [[ -n "${GIST_CORPUS_ROOT:-}" ]]; then
    (cd "${GIST_CORPUS_ROOT}" && pwd)
    return 0
  fi
  # Former monorepo nest: $REPO/pkg/kernels/<pkg>
  local parent grand great
  parent="$(basename "$(dirname "$pkg")")"
  grand="$(basename "$(dirname "$(dirname "$pkg")")")"
  great="$(cd "${pkg}/../../.." 2>/dev/null && pwd)" || great=""
  if [[ "$parent" == kernels && "$grand" == libs && -n "$great" &&
    -d "${great}/services" && -d "${great}/libs" ]]; then
    printf '%s\n' "$great"
    return 0
  fi
  # Sibling billy checkout beside this package
  if [[ -d "${pkg}/../monorepo/services" && -d "${pkg}/../monorepo/libs" ]]; then
    (cd "${pkg}/../billy" && pwd)
    return 0
  fi
  printf '%s\n' "$pkg"
}

_gist_product_root() {
  local pkg="$1"
  if [[ -f "${pkg}/../gist/build.zig.zon" ]]; then
    (cd "${pkg}/../gist" && pwd)
    return 0
  fi
  printf '%s\n' "$pkg"
}

# `relate` ships its own binary from its own checkout, so a gate that oracles
# both products cannot assume one zig-out holds them. Falls back to PRODUCT,
# which is where `relate` lived before the split.
_gist_kinship_root() {
  local pkg="$1"
  if [[ -f "${pkg}/../relate/build.zig.zon" ]]; then
    (cd "${pkg}/../relate" && pwd)
    return 0
  fi
  _gist_product_root "$pkg"
}

gist_resolve_roots() {
  local here="$1"
  KERNEL="$(_gist_climb_pkg "$here")" || {
    echo "roots.sh: no build.zig.zon above ${here}" >&2
    return 1
  }
  REPO="$(_gist_corpus_root "$KERNEL")"
  PRODUCT="$(_gist_product_root "$KERNEL")"
  KINSHIP="$(_gist_kinship_root "$KERNEL")"
  GIST_VERIFY="${GIST_DIR:-${REPO}/.local/gist-verify}"
}
