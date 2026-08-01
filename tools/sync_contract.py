#!/usr/bin/env python3
"""Verify the foreign contracts are reachable as sibling checkouts.

`contract/surface.toml` is ours. `analytic.toml` and `engine.toml` belong to
`irregex` and `kinship.toml` to `relate`. Bindings resolve them from the author
(see each language's `contract_path` / equivalent). This script fails when a
sibling is missing or its contract is absent, so a checkout of only this repo
knows what it cannot gate.

    python3 tools/sync_contract.py            # verify siblings
    python3 tools/sync_contract.py --check    # same (compat alias)
"""

from __future__ import annotations

import os
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

OWNED = {"analytic.toml": "irregex", "engine.toml": "irregex", "kinship.toml": "relate"}


def origin(name: str) -> Path | None:
    env = os.environ.get(f"IRREGEX_{name.removesuffix('.toml').upper()}_CONTRACT")
    if env:
        return Path(env)
    author = OWNED[name]
    for base in (ROOT.parent, *ROOT.parents):
        candidate = base / author / "contract" / name
        if candidate.is_file():
            return candidate
    return None


def main(argv: list[str]) -> int:
    _ = "--check" in argv  # compat: always verify
    rc = 0
    for name, author in OWNED.items():
        src = origin(name)
        if src is None:
            print(f"missing {author}/contract/{name} — clone the sibling beside gist", file=sys.stderr)
            rc = 1
            continue
        print(f"ok {name} ← {src}")
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
