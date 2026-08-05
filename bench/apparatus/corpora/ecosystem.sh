#!/usr/bin/env bash
# Materialize `ecosystem-v1` — the Layer L / Layer J corpus.
#
# The corpus is the four packages of this project side by side: the engine
# (`irregex`) and its three product faces (`gist`, `relate`, `blast`). Every one
# is public and Apache-2.0, so a stranger can rebuild the exact tree a
# certificate was measured over — which is the whole point, and the thing the
# private monorepo could never offer.
#
# WHY THIS TREE AND NOT A FAMOUS ONE. Layer L compares two index planners by the
# candidate bytes each admits, so its corpus has to make every probe class land
# strictly between "matches nothing" and "matches everything"; at either endpoint
# both planners admit the identical set and the row measures noise while feeding
# a fail-closed verdict. gist's 16k-file synthetic Go corpus is right for Layers
# A and D — race ripgrep on ground ripgrep wins — and wrong here, measurably:
# `slate.py --audit` finds nine of the twelve shared classes saturating there and
# seven of the eight stress classes vacuous. The engine checkout alone passes but
# is monoglot and half the size. This tree is genuinely polyglot — Zig, Markdown,
# Python, C, TOML, Rust, Go, shell, Vimscript — and all twenty classes
# discriminate on it.
#
#   ecosystem.sh <dir>            # from the sibling checkouts, else clone
#   ECOSYSTEM_FROM=clone …        # force the clone path (what a stranger runs)
#
# Emits the same JSON shape as the other corpus recipes: {files, bytes, sha256}.
set -euo pipefail

DEST="${1:?usage: ecosystem.sh <dir>}"
PACKAGES=(irregex gist relate blast)
ORIGIN="${ECOSYSTEM_ORIGIN:-https://github.com/The-Billy-Company}"

# The mint runs from the engine checkout, whose siblings are the other three.
SIBLINGS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

rm -rf "${DEST}"
mkdir -p "${DEST}"

for pkg in "${PACKAGES[@]}"; do
  mkdir -p "${DEST}/${pkg}"
  # `git archive HEAD`, not a copy: it emits exactly the tracked tree at the
  # current commit, so a coworker's in-flight edits and every build artifact,
  # cache, and gitignored scratch directory stay out of a measured corpus. A
  # `cp -r` here would silently fold `.zig-cache` into the byte count.
  if [[ "${ECOSYSTEM_FROM:-sibling}" == "sibling" && -d "${SIBLINGS}/${pkg}/.git" ]]; then
    git -C "${SIBLINGS}/${pkg}" archive HEAD | tar -x -C "${DEST}/${pkg}"
  else
    git clone --depth 1 --quiet "${ORIGIN}/${pkg}" "${DEST}/${pkg}.git"
    git -C "${DEST}/${pkg}.git" archive HEAD | tar -x -C "${DEST}/${pkg}"
    rm -rf "${DEST}/${pkg}.git"
  fi
done

python3 - "${DEST}" <<'PY'
import hashlib, json, sys
from pathlib import Path

root = Path(sys.argv[1])
files = sorted(p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file())
digest, total = hashlib.sha256(), 0
for rel in files:
    data = (root / rel).read_bytes()
    digest.update(rel.encode())
    digest.update(data)
    total += len(data)
print(json.dumps({"files": len(files), "bytes": total, "sha256": digest.hexdigest()}))
PY
