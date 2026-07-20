#!/usr/bin/env python3
"""Side-by-side debugger for a single mined test: materialize its fixture, run real `rg` and `gist rg` with the identical argv+stdin, and print both stdouts + exit codes for eyeballing a divergence.

Shares one replay path with the scoreboard (`_oracle`), so what you eyeball here
is byte-for-byte what `run.py` scored — including the `--pcre2` the ripgrep test
harness injects for an `is_pcre2()`-guarded case.

Usage:  python3 dbg.py <name> [<name>…].
"""

import base64
import json
from pathlib import Path
import sys
import tempfile

import _oracle as O


HERE = Path(__file__).resolve().parent
spec = {r["name"]: r for r in json.loads((HERE / "spec.json").read_text())}


def show(n):
    """Perform show."""
    r = spec[n]
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        O.materialize(r, root)
        cwd = str(root / r["current_dir"]) if r["current_dir"] else str(root)
        stdin = base64.b64decode(r["stdin"]) if r["stdin"] else None
        rc_rg, out_rg, err_rg = O.run(O.rg_cmd(r), cwd, stdin)
        rc_g, out_g, err_g = O.run(O.gist_cmd(r), cwd, stdin)
    print(
        f"### {n}  term={r['terminal']}  argv={O.argv_for(r)}  files={[f['path'] for f in r['files']]} dirs={r['dirs']}"
    )
    print(f"  rc rg={rc_rg} gist={rc_g}")
    print("  --- rg stdout ---")
    print("   " + out_rg.decode("utf-8", "replace").replace("\n", "\n   ")[:600])
    print("  --- gist stdout ---")
    print("   " + out_g.decode("utf-8", "replace").replace("\n", "\n   ")[:600])
    if err_rg.strip():
        print("  rg stderr:", err_rg.decode("utf-8", "replace")[:200])
    if err_g.strip():
        print("  gist stderr:", err_g.decode("utf-8", "replace")[:200])


for name in sys.argv[1:]:
    show(name)
