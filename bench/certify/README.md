# bench/certify

The **macroscopic** half of the Layer-A optimality certificate (see
`../README.md` § "Certificate of Optimality"). The microscopic half
(`zig build certify`, single-threaded cycles/byte) lives in
[`../harness/`](../harness/README.md); this half proves the _end-to-end_ claim
a user actually cares about: for every regex class ripgrep supports, gist's
cold fresh-process query is **at parity or faster than ripgrep**, established
with a real statistic — not a single mean.

| File               | Role                                                                                                                                                         |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `certify.sh`       | races gist + the whole field (via `../races/_compete.sh`) over 11 probe classes, hyperfine JSON per (class, tool)                                            |
| `certify_stats.py` | a stdlib mirror of `../harness/stats.zig` — per-class bootstrap-CI median + Mann-Whitney verdict, splices the table into `.local/gist-verify/CERTIFICATE.md` |

The 11 classes are byte-identical to `../harness/certify.zig`'s probes, so the
macroscopic table here and the microscopic table there map 1:1 by class name.
The verdict is **fail-closed** — a WIN needs a lower median _and_
Mann-Whitney `p<0.05`; every class is shown, losses and the indexed-twin
(csearch/zoekt) context included. Unlike the selective-needle cold sweep in
`../races/`, the 11 probe classes here deliberately include the **saturating**
patterns (`})`, `;$`, `\w{3,8}`, a UUID class) where the trigram prefilter
admits _every_ file — the cases the competition is built to win.

```bash
cd pkg/kernels/gist
RUNS=20 bench/certify/certify.sh        # default RUNS=20 WARMUP=3; raise RUNS to tighten CIs
```
