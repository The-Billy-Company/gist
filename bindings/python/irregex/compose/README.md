# `irregex.compose` — both engines on one question

ADR-367's composed face: an exact pattern set narrows the corpus, and the
compression engine reasons **inside that subset**. The two scores stay in separate
fields — a composed answer never fuses an exact match count with a statistical
distance into one number.

| Module      | Concern                                                                                                                                                   |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `verbs.py`  | `context` (reading set among matching files) · `family` (forks and renamed twins among them) · `provenance` (quotation re-verified against current bytes) |
| `radius.py` | `blast` — the live blast radius of a symbol: dependents, dependencies, twins, ripple, and the comments that mention it, all from current bytes            |

`provenance` is the sharp one: `relate quote` attributes phrases against a
snapshot shelf, while `provenance` re-checks each phrase against the source
file's bytes _now_ — so a phrase whose file has since changed simply does not
appear. That difference is the reason both verbs exist.
