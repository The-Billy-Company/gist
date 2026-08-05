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

The default is deliberately small (~200 files): the slowest execution lane is a
foreign-arch QEMU container, where a full-repo sweep would cost minutes per
target. `--files N` scales it up for the certificate corpus, which needs a tree
big enough that a timing measures search rather than process startup. Because
one seeded RNG is consumed in file order, **a small corpus is a byte-exact
prefix of a large one** — the 200-file portability tree is the first 200 files
of the 4,000-file certificate tree, so the two lanes never disagree about what a
probe class means.

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


#: How often a file is a database service, and so the only kind that mentions
#: `pgxpool`. Selectivity is the whole point of the `literal-rare` and
#: `regex-dotted` probe classes: they exist to measure what an index buys when a
#: needle is in a *few* files, and a corpus where every file imports pgx makes
#: them saturating classes wearing a selective class's name — the floors would
#: still be met, by a measurement of something else. One in 64 keeps the needle
#: rare while leaving hundreds of hits in a certificate-sized tree.
POOL_EVERY = 64
#: How often a file's methods take a `context.Context`. Moderately selective, so
#: `literal-dotted` sits between the rare and the saturating classes rather than
#: collapsing onto one of them. A multiple of nothing in particular except that
#: `POOL_EVERY % CTX_EVERY == 0`, which makes every pool file a ctx file too —
#: the real-world containment, not an independent coin flip.
CTX_EVERY = 4


def _body(rng: random.Random, i: int) -> str:
    """One synthetic Go file. Every probe class matches *something*; two match rarely."""
    typ, verb, pool = rng.choice(TYPES), rng.choice(VERBS), rng.choice(POOLS)
    pooled, ctxed = i % POOL_EVERY == 0, i % CTX_EVERY == 0
    # The store is what a non-database service holds instead of a pool, so the
    # shape of every file is the same and only the vocabulary is selective.
    field, ctor = (f"pool *{pool}", pool) if pooled else ("store *memstore.Store", "memstore.Store")
    imports = ['\t"errors"', '\t"strings"']
    if ctxed:
        imports.insert(0, '\t"context"')
    imports.append('\t"github.com/jackc/pgx/v5/pgxpool"' if pooled else '\t"internal/memstore"')
    out = [
        f"package svc{i % 7}",
        "",
        "import (",
        *imports,
        ")",
        "",
        f"// {typ}Service — trace {_uuid_like(rng)}",
        f"type {typ}Service struct {{",
        f"\t{field}",
        f"\tflags uint32 // 0x{rng.randrange(1 << 16):04x}",
        "}",
        "",
        # A free function, so `func\s+\w+\(` and `^func\s` match in every file
        # rather than only in the rarer `panic` files (methods read
        # `func (s *T) …`, which the decl class deliberately does not match).
        f"func new{typ}Service(src *{ctor}) *{typ}Service {{",
        f"\treturn &{typ}Service{{{field.split()[0]}: src}};",
        "}",
        "",
    ]
    holder = "s.pool" if pooled else "s.store"
    signature = "ctx context.Context, id string" if ctxed else "id string"
    call = f"{holder}.{rng.choice(VERBS)}({'ctx' if ctxed else 'id'})"
    for n in range(rng.randrange(3, 8)):
        # `^func` needs column-zero declarations; the interior lines carry the
        # `;$`, alternation, and `})` classes, which must stay in EVERY file —
        # they are the saturating classes, and a saturating class that thinned
        # out would quietly become a selective one.
        out += [
            f"func (s *{typ}Service) {verb}{n}({signature}) error {{",
            f"\tconn, err := {call};",
            "\tif err != nil {",
            f'\t\treturn errors.New("{typ.lower()}: {verb.lower()} failed");',
            "\t}",
            "\tfor _, row := range conn.Rows() {",
            f'\t\tif row.ID == "{_uuid_like(rng)}" {{',
            "\t\t\tcontinue",
            "\t\t}",
            f"\t\tif row.Kind == 0x{rng.randrange(1 << 12):03x} {{",
            "\t\t\tbreak",
            "\t\t}",
            f'\t\tif strings.HasPrefix(row.Name, "{verb.lower()}") {{',
            "\t\t\treturn nil",
            "\t\t}",
            "\t}",
            # A closure argument closed on its own line is what puts the `})`
            # punctuation pair in the corpus — the class the trigram index cannot
            # prefilter, so it must be present or that probe conforms vacuously.
            f"\t{holder}.OnClose(func() {{",
            "\t\t_ = conn.Close();",
            "\t})",
            "\treturn nil",
            "}",
            "",
        ]
    if i % 17 == 0:  # the `panic|0x` litalt class wants real panics too
        out += [f"func mustSeal{i}(v uint64) {{", '\tpanic("unsealed")', "}", ""]
    return "\n".join(out) + "\n"


def generate(root: Path, files: int = FILES) -> dict:
    """(Re)create the corpus at `root`. Returns `{files, bytes, sha256}`.

    The digest covers every path and its bytes in sorted order, so the harness can
    *prove* the native oracle and each container read the same tree rather than
    assuming it — a bind-mount that dropped or reordered files would change it.

    `files` scales the tree without changing any file already in it: the RNG is
    consumed strictly in file order, so file *i* is a function of the seed and
    *i* alone.
    """
    if root.exists():
        shutil.rmtree(root)
    rng = random.Random(SEED)
    total = 0
    for i in range(files):
        path = root / f"pkg{i % 11:02d}" / f"svc{i:03d}.go"
        path.parent.mkdir(parents=True, exist_ok=True)
        data = _body(rng, i).encode()
        path.write_bytes(data)
        total += len(data)
    # Digested by reading back what landed on disk, through the same function the
    # container-side check uses: one definition, so a digest can never agree with
    # the writer's intent while disagreeing with the bytes a reader will see.
    return {"files": files, "bytes": total, "sha256": digest_of(root)}


def selectivity(root: Path) -> dict[str, float]:
    """Fraction of files each probe class matches, measured over the generated tree.

    The corpus is only useful if it reproduces the *shape* of the question, not
    just the vocabulary. Two classes must stay rare (`literal-rare`,
    `regex-dotted`) or the floors that exist to price index selectivity end up
    pricing a full scan; the rest must stay saturating or the certificate stops
    racing ripgrep on the ground ripgrep wins. Measured with Python's own regex
    over the bytes on disk, so nothing here depends on the tool under test.

    """
    import re as _re

    from matrix import PROBES

    files = sorted(root.rglob("*.go"))
    hits = dict.fromkeys((cls for cls, _, _ in PROBES), 0)
    compiled = [
        (cls, _re.compile(_re.escape(pat) if kind == "literal" else pat, _re.MULTILINE))
        for cls, kind, pat in PROBES
    ]
    for path in files:
        text = path.read_text(errors="replace")
        for cls, rx in compiled:
            if rx.search(text):
                hits[cls] += 1
    return {cls: n / len(files) for cls, n in hits.items()} if files else {}


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
    import argparse
    import json
    import sys
    import tempfile

    ap = argparse.ArgumentParser(description="generate the deterministic Go-shaped corpus")
    ap.add_argument("root", nargs="?", default="/tmp/gist-portable-corpus")
    ap.add_argument("--files", type=int, default=FILES, help=f"tree size (default {FILES})")
    args = ap.parse_args()

    if args.root == "selftest":
        # Determinism, then the claim that matters: no probe class is vacuous and
        # the selective ones are actually selective, then that scaling only ever
        # appends — a big tree must contain a small one byte for byte, or the two
        # lanes are measuring different corpora.
        with tempfile.TemporaryDirectory() as td:
            a, b, wide = Path(td) / "a", Path(td) / "b", Path(td) / "wide"
            meta, again = generate(a), generate(b)
            assert meta == again, f"non-deterministic: {meta} != {again}"
            assert digest_of(a) == meta["sha256"], "digest_of disagrees with generate"

            share = selectivity(a)
            if vacuous := sorted(cls for cls, frac in share.items() if frac == 0.0):
                raise SystemExit(f"corpus: probe classes match nothing: {', '.join(vacuous)}")
            for cls in ("literal-rare", "regex-dotted"):
                if not 0.0 < share[cls] <= 0.10:
                    raise SystemExit(
                        f"corpus: {cls} matches {share[cls]:.1%} of files — it is the class "
                        "that prices index selectivity and must stay rare (raise POOL_EVERY)"
                    )
            for cls in ("literal-common", "literal-punct2", "regex-eol", "regex-dense-scan"):
                if share[cls] < 1.0:
                    raise SystemExit(
                        f"corpus: {cls} matches {share[cls]:.1%} of files — it is a saturating "
                        "class and must be in every file, or gist races rg on easier ground"
                    )

            generate(wide, FILES * 2)
            for path in a.rglob("*.go"):
                rel = path.relative_to(a)
                assert (wide / rel).read_bytes() == path.read_bytes(), f"scaling rewrote {rel}"
            print(json.dumps(meta | {"selectivity": {k: round(v, 4) for k, v in share.items()}}))
        sys.exit(0)
    print(json.dumps(generate(Path(args.root), args.files)))
