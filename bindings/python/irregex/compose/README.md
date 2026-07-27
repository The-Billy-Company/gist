# `irregex.compose` — both engines on one question

ADR-367's composed face: an exact pattern set narrows the corpus, and the
compression engine reasons **inside that subset**. The two scores stay in separate
fields — a composed answer never fuses an exact match count with a statistical
distance into one number.

Composition is a **modifier**, not a verb family. Most composed questions are
spelled `matching=[…]` on the relate/kinship functions they already belong to
(`pack(text, matching=[…])`, `families(matching=[…], unit="function")`,
`similar(probe, matching=[…])`). What remains here are the two verbs that are
a different _act_, not a narrowing of an existing question:

| Module      | Concern                                                                                                            |
| ----------- | ------------------------------------------------------------------------------------------------------------------ |
| `verbs.py`  | `provenance` — quotation attribution re-verified against each source file's **current** bytes, not a shelf snapshot |
| `radius.py` | `blast` — the live blast radius of a symbol: dependents, dependencies, twins, ripple, and mentions                 |

`provenance` is the sharp one: `relate quote` attributes phrases against a
snapshot shelf, while `provenance` re-checks each phrase against the source
file's bytes _now_ — so a phrase whose file has since changed simply does not
appear. That difference is the reason both verbs exist.
