# `irregex.relate` — kinship and retrieval

The questions a regex cannot ask. Everything here is priced in **bits**: how
cheaply would this file describe that one, or this corpus describe your text.

| Module         | Concern                                                                                                                               |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `corpus.py`    | the shared scope/argv vocabulary and the graded result container every kinship verb returns                                           |
| `kinship.py`   | the two questions — `similar` (neighbors of one probe) · `pairs` / `families` / `distinct` (what repeats, on `channel` × `unit` axes) |
| `retrieval.py` | retrieval — `recall` (rank by describability) · `pack` (the anti-redundant reading set) · `quote` (the text as corpus quotations)     |
| `sweep.py`     | `patterns` / `pattern_counts` — N patterns, one walk, exact per-pattern attribution                                                   |

Two things to keep in mind when reading results here:

**A distance is not an answer.** Every row carries a calibrated grade, and an
answer made only of background says so instead of looking like a hit. The bands
come from the kernel's calibration, mirrored in `../contract/grades.py`.

**Absence is a measurement.** `distance = 0.0` means _identical_, which is why the
row decoder keeps _unmeasured_ and _zero_ strictly apart, on every transport.
