---
doc_radar:
  sentinels:
    - file: pkg/kernels/irregex/include/irregex.h
      contains:
        - "irregex_analytic_run"
        - "irregex_rows_next_batch"
        - "irregex_rows_stats"
        - "irregex_schema_digest"
      description: The analytic entry points this package dispatches through are the header's, so a rename here cannot drift silently.
---

# `irregex.runtime` — transports, and the ladder between them

One question can be answered by three different machines. This package owns all
of them and the order they are tried in, so no verb ever has to know which one
answered.

```text
native (in-process C ABI)  →  UDS daemon (exact search only)  →  subprocess CLI
```

| Module        | Concern                                                                                                                                           |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `native.py`   | loads `libirregex` through cffi, declares the C ABI, probes which symbols a given library actually exports, and owns the warm exact-search handle |
| `analytic.py` | the analytic plane: `irregex_analytic_run` dispatch, the `Rows` cursor, `Stats`, and the schema-digest check                                      |
| `params.py`   | the five parameter families — one struct per _kind_ of question, lowered into the C params union                                                  |
| `decode.py`   | **the** row decoder — one schema walk for every verb, in either transport                                                                         |
| `cold.py`     | the subprocess tier presented as rows: `--json` objects lifted into the same positional `Row` the C cursor produces                               |
| `shell.py`    | the subprocess engine adapter for exact search — argv lowering, `--json` parsing, the `--rank` scrape                                             |
| `daemon.py`   | the UDS client for a running `gist serve`, with its own eligibility rules                                                                         |
| `errors.py`   | the typed error surface, including `SchemaDriftError` and `RowDecodeError`                                                                        |

## Three properties the ladder rests on

**A declinature is not an error.** `IRREGEX_STALE` means _this tier cannot answer
this request_ — a pattern needing PCRE2, a scope the handle does not cover, a
verb an older library does not export. The answer then comes from the next rung
down and is the same answer. It is never raised, and a caller cannot tell which
tier served them except by reading `Stats.source`.

**The plane is probed, never assumed.** A library built before ADR-377 exports
none of the analytic symbols; `native.exports(...)` notices, and every verb keeps
working through the CLI. The absence of the plane is not a failure.

**A drifted schema table is fatal.** `verify()` compares this binding's
`DIGEST` with `irregex_schema_digest()` at load, and names the differing schemas
via `irregex_schema_get` when they disagree. This is the one thing that cannot
degrade gracefully: decoding rows against the wrong table produces values that
are the right _type_ and the wrong _field_.

## Rows

`Rows` is an analytic answer. Iterate it for one record at a time, `batches(n)`
to trade call overhead for a wider window (each batch is one
`irregex_rows_next_batch`), or `drain()` for everything.

Every record is an **owned Python object**. Native rows borrow the cursor arena
and are invalid after the next pull, so materializing before yielding is not a
convenience — it is what makes the API safe. `Stats` is snapshotted at close for
the same reason.

`Stats.foreign` and `Stats.omitted` are load-bearing: the first distinguishes
_your text is not in this corpus_ from _no results_, the second says a budget
truncated the answer.
