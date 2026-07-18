#!/usr/bin/env python3
"""Side-by-side debugger for a single mined test: materialize its fixture, run real `rg` and `gist rg` with the identical argv+stdin, and print both stdouts + exit codes for eyeballing a divergence.

Usage:  python3 dbg.py <name> [<name>…].
"""

import base64
import contextlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
GIST = HERE.parents[1] / "zig-out" / "bin" / "gist"  # the CLI (`rg` verb), not the bench harness
spec = {r["name"]: r for r in json.loads((HERE / "spec.json").read_text())}


def show(n):
    """Perform show."""
    r = spec[n]
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        for d in r["dirs"]:
            (root / d).mkdir(parents=True, exist_ok=True)
        for f in r["files"]:
            p = root / f["path"]
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(base64.b64decode(f["b64"]))
        for s in r.get("sized", []):
            p = root / s["path"]
            p.parent.mkdir(parents=True, exist_ok=True)
            with p.open("wb") as fh:
                fh.truncate(int(s["size"]))
        for link in r.get("symlinks", []):
            p = root / link["path"]
            p.parent.mkdir(parents=True, exist_ok=True)
            if p.is_symlink() or p.exists():
                with contextlib.suppress(OSError):
                    p.unlink()
            p.symlink_to(root / link["target"])
        cwd = str(root / r["current_dir"]) if r["current_dir"] else str(root)
        kw = (
            {"input": base64.b64decode(r["stdin"])} if r["stdin"] else {"stdin": subprocess.DEVNULL}
        )
        rr = subprocess.run(
            ["rg", "--path-separator", "/"] + r["argv"], cwd=cwd, capture_output=True, **kw
        )
        gg = subprocess.run([str(GIST), "rg"] + r["argv"], cwd=cwd, capture_output=True, **kw)
    print(f"### {n}  argv={r['argv']}  files={[f['path'] for f in r['files']]} dirs={r['dirs']}")
    print(f"  rc rg={rr.returncode} gist={gg.returncode}")
    print("  --- rg stdout ---")
    print("   " + rr.stdout.decode("utf-8", "replace").replace("\n", "\n   ")[:600])
    print("  --- gist stdout ---")
    print("   " + gg.stdout.decode("utf-8", "replace").replace("\n", "\n   ")[:600])
    if gg.returncode == 2:
        print("  gist stderr:", gg.stderr.decode()[:150])


for name in sys.argv[1:]:
    show(name)
