#!/usr/bin/env bash
# Climb-don't-count resolvers for the post-split layout.
#
# VENDORED, BYTE-IDENTICAL. Every package in the ecosystem carries its own copy
# at `bench/apparatus/roots.sh`, held identical by a pinned digest
# (`bench/apparatus/SHARED.sha256`, checked by `shared_drift.py`). Four
# independently releasable packages cannot source shell across repository
# boundaries, and two copies that answer "where are my siblings?" differently is
# how a gate silently measures the wrong tree. Edit once, run the gate, paste the
# new digest into every copy in the same change.
#
# Source from a bench script after setting HERE to that script's directory:
#   # shellcheck source=../apparatus/roots.sh
#   source "${HERE}/../../apparatus/roots.sh"   # adjust depth
#   gist_resolve_roots "${HERE}"
#
# Exports:
#   KERNEL      — package root (build.zig.zon), climbed from HERE
#   CORPUS      — the tree being MEASURED (GIST_CORPUS_ROOT, else KERNEL)
#   ENGINE      — checkout that owns the irregex library (sibling, else KERNEL)
#   PRODUCT     — checkout that owns the product binary (sibling, else KERNEL)
#   KINSHIP     — checkout that owns the kinship binary (sibling, else PRODUCT)
#   GIST_VERIFY — GIST_DIR or ${CORPUS}/.gist (artifact home)
#
# There is deliberately no `REPO`. It used to name the corpus here and the
# package in `field.sh`, which is how a mint came to hash a manifest relative to
# the checkout while its path list was relative to a corpus snapshot — every row
# a real file with a real digest, and none of them the bytes that were searched.
# A checkout is KERNEL and a measured tree is CORPUS, in every package.

_gist_climb_pkg() {
  local d="$1"
  while [[ -n "${d}" && "${d}" != / ]]; do
    if [[ -f "${d}/build.zig.zon" ]]; then
      printf '%s\n' "${d}"
      return 0
    fi
    d="$(dirname "${d}")"
  done
  return 1
}

# The declared package name (`.name = .gist,`), so a checkout can recognize
# ITSELF as the sibling being asked for. Without this, resolution depends on the
# directory being named exactly like the package — false for an exported tarball,
# a versioned unpack, or a worktree.
_gist_pkg_name() {
  sed -n 's/^[[:space:]]*\.name[[:space:]]*=[[:space:]]*\.\([A-Za-z_][A-Za-z0-9_]*\).*/\1/p' \
    "$1/build.zig.zon" 2>/dev/null | head -n 1
}

# Resolve sibling package <name> from <pkg>, in precedence order:
#   1. an explicit override (IRREGEX_ROOT / GIST_ROOT / RELATE_ROOT / BLAST_ROOT)
#   2. this package, when this package IS the one being asked for
#   3. a sibling checkout that DECLARES that package name (any directory name)
# Prints nothing and returns 1 when none of those hold; the caller picks a
# fallback, because "absent" and "is me" are different answers.
_gist_sibling() {
  local pkg="$1" want="$2" override
  override="$(printf '%s_ROOT' "$(printf '%s' "${want}" | tr '[:lower:]' '[:upper:]')")"
  if [[ -n "${!override:-}" ]]; then
    (cd "${!override}" && pwd)
    return 0
  fi
  if [[ "$(_gist_pkg_name "${pkg}")" == "${want}" ]]; then
    printf '%s\n' "${pkg}"
    return 0
  fi
  local cand
  for cand in "${pkg}/../${want}" "${pkg}/../${want}"-*; do
    [[ -f "${cand}/build.zig.zon" ]] || continue
    [[ "$(_gist_pkg_name "${cand}")" == "${want}" ]] || continue
    (cd "${cand}" && pwd)
    return 0
  done
  return 1
}

# The corpus is an input, not something to go looking for. This used to sniff for
# the monorepo the package was extracted from and then for a checkout of it beside
# this one, which meant a gate's corpus silently became whatever private tree
# happened to sit next door — unreproducible, and different on every machine. Set
# GIST_CORPUS_ROOT to say what to measure over
# (`bench/apparatus/corpora/fetch.sh` in the exact-search package pins public
# ones); absent that, a package measures itself.
_gist_corpus_root() {
  local pkg="$1"
  if [[ -n "${GIST_CORPUS_ROOT:-}" ]]; then
    (cd "${GIST_CORPUS_ROOT}" && pwd)
    return 0
  fi
  printf '%s\n' "${pkg}"
}

gist_resolve_roots() {
  local here="$1"
  KERNEL="$(_gist_climb_pkg "${here}")" || {
    echo "roots.sh: no build.zig.zon above ${here}" >&2
    return 1
  }
  CORPUS="$(_gist_corpus_root "${KERNEL}")"
  ENGINE="$(_gist_sibling "${KERNEL}" irregex)" || ENGINE="${KERNEL}"
  PRODUCT="$(_gist_sibling "${KERNEL}" gist)" || PRODUCT="${KERNEL}"
  # The kinship face ships its own binary from its own checkout, so a gate that
  # oracles both products cannot assume one zig-out holds them. Falls back to
  # PRODUCT, which is where that face lived before the split.
  KINSHIP="$(_gist_sibling "${KERNEL}" relate)" || KINSHIP="${PRODUCT}"
  GIST_VERIFY="${GIST_DIR:-${CORPUS}/.gist}"

  export KERNEL CORPUS ENGINE PRODUCT KINSHIP GIST_VERIFY
}
