# bench/certificate/mint

The **minting scripts** — the executable half of the certificate. `mint.sh` is
the one entry point (`bash bench/certificate/mint/mint.sh`); the rest are lanes it splices
in. Every lane sources the competitor field at
[`../../dominance/races/field.sh`](../../dominance/races/field.sh) and writes its
splicer's output into `.local/gist-verify/CERTIFICATE.md`.

| File        | Lane                                                                                                                                                                             |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `mint.sh`   | full A–G mint — Layer A micro (+ optional sudo PMU) + macroscopic field race + warm tier + `--rank` lane + relate, auto-calls `splice.sh`; the `bash bench/certificate/mint/mint.sh` default |
| `splice.sh` | Layers B/B′/C/D/E/F — builds the lab bins, measures, and splices each `bounds/` report + Layer E crest back into the certificate (was `certify_layers.sh`)                       |
| `warm.sh`   | Layer A warm-tier lane — the resident daemon vs cold gist + rivals                                                                                                               |
| `rank.sh`   | Layer A `--rank` lane — no-fabrication / coverage / def-boost / demotion / bounded-overhead / selective-beats-rg                                                                 |
| `relate.sh` | Layer G lane — the relate face's retrieval-quality contract + boundary                                                                                                           |
| `crest.sh`  | Layer E lane — the crest-sieve prune/speedup table                                                                                                                               |

Reports live in [`../report/`](../report/README.md), guards in
[`../guard/`](../guard/README.md), the append-only mint history in
[`../ledger/`](../ledger/README.md), and the frozen published bundle in
`../artifact/`.

```bash
bash bench/certificate/mint/mint.sh                                           # B–F refresh (fast)
CERT_FULL=1 CERT_PUBLISH=1 CERT_SUDO=1 bash bench/certificate/mint/mint.sh    # full mint + publish
```
