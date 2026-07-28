# bench/certificate/ledger

The **certificate's memory.** A mint rewrites the whole certificate, so every
publish is honest on its own and amnesiac about the last one — a re-mint that
improves eight numbers looks identical to one that also dropped a layer. This
ledger closes that gap: one append-only row per publish.

| File             | Role                                                                                                                                                                                                                     |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ledger.py`      | appends one row per published certificate (corpus, layers carried, verdict tally, cold + crest geomeans) keyed by a digest of `CERTIFICATE.md`; imports the layer roster from [`../guard/layers.py`](../guard/README.md) |
| `ledger.jsonl`   | the append-only machine record — **never hand-edited**, written only by `ledger.py`                                                                                                                                      |
| `LEDGER.md`      | the rendered look-back table                                                                                                                                                                                             |
| `test_ledger.py` | unit test                                                                                                                                                                                                                |

```bash
make bench-gist-ledger                                 # survey: is the on-disk certificate recorded?
make bench-gist-ledger ARGS="verify"                   # fail-closed on unrecorded drift
make bench-gist-ledger ARGS="verify --require-layers"  # …and on an incomplete mint
```

`verify` fails on **unrecorded drift**; a missing layer is always reported but
only fails under `--require-layers`, because the two have different remedies —
`record` clears drift, only re-splicing clears a gap.
