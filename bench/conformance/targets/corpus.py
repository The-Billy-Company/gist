#!/usr/bin/env python3
"""The conformance corpus — generated, not checked in, byte-identical every run.

A cross-target conformance diff is only as good as the tree both binaries read.
Pointing the harness at the repo would make the comparison depend on whatever the
~10 coworker agents saved in the last second, so the corpus is *synthesized* from
a fixed seed: same bytes on every machine, every run, inside every container.

It is shaped to make all twelve of `bench/harness/probes.zig`'s query classes
answer non-trivially — a probe that matches nothing conforms vacuously, which is
the failure mode that makes a green portability sweep worthless. `selftest`
asserts exactly that (every probe non-empty, at least one multi-file), so the
corpus cannot silently stop exercising a class.

Deliberately small (~200 files): the slowest execution lane is a foreign-arch
QEMU container, where a full-repo sweep would cost minutes per target.

stdlib only.
"""

from __future__ import annotations

import hashlib
import random
import shutil
from pathlib import Path

# Vocabulary chosen so each probe class lands somewhere: `pgxpool` (rare literal)
# and `pgxpool.Acquire` (dotted), `context.Context`, `func` (common), `})`
# (punctuation pair), `^func` (anchored), hex UUID prefixes, the
# return/continue/break alternation, `;$` line ends, and `panic`/`0x`.
TYPES = ("Wallet", "Ledger", "Session", "Corpus", "Router", "Shard", "Beacon", "Anchor")
VERBS = ("Acquire", "Release", "Commit", "Reconcile", "Resolve", "Drain", "Seal", "Probe")
POOLS = ("pgxpool.Pool", "pgxpool.Conn", "pgxpool.Tx")

FILES = 200
SEED = 0x9E3779B97F4A7C15


def _uuid_like(rng: random.Random) -> str:
    h = "".join(rng.choice("0123456789abcdef") for _ in range(32))
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"


def _body(rng: random.Random, i: int) -> str:
    typ, verb, pool = rng.choice(TYPES), rng.choice(VERBS), rng.choice(POOLS)
    out = [
        f"package svc{i % 7}",
        "",
        "import (",
        '\t"context"',
        '\t"errors"',
        '\t"github.com/jackc/pgx/v5/pgxpool"',
        ")",
        "",
        f"// {typ}Service — trace {_uuid_like(rng)}",
        f"type {typ}Service struct {{",
        f"\tpool *{pool}",
        f"\tflags uint32 // 0x{rng.randrange(1 << 16):04x}",
        "}",
        "",
        # A free function, so `func\s+\w+\(` and `^func\s` match in every file
        # rather than only in the rarer `panic` files (methods read
        # `func (s *T) …`, which the decl class deliberately does not match).
        f"func new{typ}Service(pool *{pool}) *{typ}Service {{",
        f"\treturn &{typ}Service{{pool: pool}};",
        "}",
        "",
    ]
    for n in range(rng.randrange(3, 8)):
        # `^func` needs column-zero declarations; the interior lines carry the
        # `;$`, alternation, and `})` classes.
        out += [
            f"func (s *{typ}Service) {verb}{n}(ctx context.Context, id string) error {{",
            f"\tconn, err := s.pool.{rng.choice(VERBS)}(ctx);",
            "\tif err != nil {",
            f"\t\treturn errors.New(\"{typ.lower()}: {verb.lower()} failed\");",
            "\t}",
            "\tfor _, row := range conn.Rows() {",
            f"\t\tif row.ID == \"{_uuid_like(rng)}\" {{",
            "\t\t\tcontinue",
            "\t\t}",
            f"\t\tif row.Kind == 0x{rng.randrange(1 << 12):03x} {{",
            "\t\t\tbreak",
            "\t\t}",
            "\t}",
            # A closure argument closed on its own line is what puts the `})`
            # punctuation pair in the corpus — the class the trigram index cannot
            # prefilter, so it must be present or that probe conforms vacuously.
            f"\ts.pool.OnClose(func() {{",
            "\t\t_ = conn.Close();",
            "\t})",
            "\treturn nil",
            "}",
            "",
        ]
    if i % 17 == 0:  # the `panic|0x` litalt class wants real panics too
        out += [f"func mustSeal{i}(v uint64) {{", '\tpanic("unsealed")', "}", ""]
    return "\n".join(out) + "\n"


def generate(root: Path) -> dict:
    """(Re)create the corpus at `root`. Returns `{files, bytes, sha256}`.

    The digest covers every path and its bytes in sorted order, so the harness can
    *prove* the native oracle and each container read the same tree rather than
    assuming it — a bind-mount that dropped or reordered files would change it.
    """
    if root.exists():
        shutil.rmtree(root)
    rng = random.Random(SEED)
    total = 0
    for i in range(FILES):
        path = root / f"pkg{i % 11:02d}" / f"svc{i:03d}.go"
        path.parent.mkdir(parents=True, exist_ok=True)
        data = _body(rng, i).encode()
        path.write_bytes(data)
        total += len(data)
    # Digested by reading back what landed on disk, through the same function the
    # container-side check uses: one definition, so a digest can never agree with
    # the writer's intent while disagreeing with the bytes a reader will see.
    return {"files": FILES, "bytes": total, "sha256": digest_of(root)}


def digest_of(root: Path) -> str:
    """Path-and-bytes digest of the corpus at `root`, in sorted path order.

    Both the native oracle's tree and each container's view of it are digested
    with this, so a bind mount that dropped, reordered, or altered a file fails
    the sweep instead of quietly narrowing the conformance comparison.
    """
    d = hashlib.sha256()
    rels = sorted(p.relative_to(root).as_posix() for p in root.rglob("*.go"))
    for rel in rels:
        d.update(rel.encode())
        d.update((root / rel).read_bytes())
    return d.hexdigest()


if __name__ == "__main__":
    import json
    import sys
    import tempfile

    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        # Determinism, then the claim that matters: no probe class is vacuous.
        with tempfile.TemporaryDirectory() as td:
            a, b = Path(td) / "a", Path(td) / "b"
            ma, mb = generate(a), generate(b)
            assert ma == mb, f"non-deterministic: {ma} != {mb}"
            assert digest_of(a) == ma["sha256"], "digest_of disagrees with generate"
            print(json.dumps(ma))
        sys.exit(0)
    print(json.dumps(generate(Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/gist-portable-corpus"))))
