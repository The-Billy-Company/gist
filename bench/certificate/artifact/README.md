---
doc_radar:
  sentinels:
    - description: "artifact validation requires all generated layer sidecars"
      file: bench/certificate/guard/layers.py
      contains: ["portcert.json", "roofline.json", "lowerbound.csv", "crest.csv"]
    - description: "the committed ratio gate reads this artifact"
      file: bench/certificate/guard/ratio.py
      contains: "certify_macro.csv"
---

# Committed certificate artifact

Seven-layer bundle (A micro + A macro + warm + `--rank` + B/B′ + C + D + E + F + G).
Publish with a **clean** git tree (or an isolated `git worktree`):

This snapshot certifies only `gist`'s fresh-process cold exact-search path over
the shared 12 literal/regex classes. It is not evidence for every CLI mode,
`--include-zero`, warm daemon traffic, `relate`, or composed `irregex`.

```bash
# From this package root:
CERT_FULL=1 CERT_PUBLISH=1 CERT_SUDO=1 bash bench/certificate/mint/mint.sh
python3 bench/certificate/guard/artifacts.py \
  --artifacts-dir bench/certificate/artifact --artifacts
python3 bench/certificate/guard/ratio.py --committed
python3 bench/certificate/ledger/ledger.py record --bundle bench/certificate/artifact
```

`machine.json` records the minting `git_commit` as **provenance only** — a
thread a human can pull to find the tree a number came from. No check resolves
or compares it, and none fails without it, so a bundle from a dirty tree or an
exported tarball is judged exactly like any other: on its bytes. Minting still
refuses a dirty tree unless `CERT_ALLOW_DIRTY=1` (local exploratory evidence,
not a publishable snapshot). `artifacts.py` fail-closes if Layers B–G headers or sidecars
named by the shared `../guard/layers.py` roster (`portcert.json` / `roofline.json` /
`lowerbound.csv` / `crest.csv` / etc.) are absent.

Because a mint rewrites this whole bundle, every publish also appends a row to
[`../ledger/LEDGER.md`](../ledger/LEDGER.md) recording what that certificate claimed and which
layers it carried — the tree's only memory of the previous one.
Ratio floors live in `../guard/ratio_baseline.json` and are gated by
`python3 bench/certificate/guard/ratio.py --committed`.

## Per-platform release bundles

This flat directory is the current-machine mint (the Mac today). A **release**
additionally requires the certificate re-minted on the Linux machine, published
beside it under a per-platform subdir (never overwriting the flat Mac bundle):

```bash
CERT_PUBLISH_DIR=bench/certificate/artifact/linux-x86_64 bash bench/certificate/mint/mint.sh
```

`../guard/release.py` verifies both platforms are present and valid; Town Crier
(`changelog build`) runs it before cutting an irregex release.
