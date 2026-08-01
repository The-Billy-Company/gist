# `irregex.index` — artifact lifecycle

Warmth is about speed, never correctness. Every verb answers with or without a
persisted artifact; this package is how a long-running process decides warmth
**once** instead of paying a cold corpus walk per call.

`lifecycle.py` covers both planes:

- the exact trigram index — `status()` / `index()` and the capability manifest;
- the compression artifacts — the kinship `atlas`, the `fragments` table, and the
  codex `shelf`, reported independently because the verbs are independent.

The one artifact that is a genuine dependency is the shelf: `quote` and
`provenance` require it, which is what `can_quote` is for — preflight it rather
than catching the failure. Everything else degrades to a live rebuild with
byte-identical answers.
