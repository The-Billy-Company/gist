"""How an answer actually gets here — the transports, the decoder, and the ladder.

Every verb in this binding is answered by the same certified engine; the only
question is which door it came through. This package owns all of them and the
order they are tried in:

    native (in-process C-ABI)  →  resident session (UDS)  →  subprocess CLI

Each rung is *complete on its own*, so a fall to the next one changes the
latency and nothing else. A declinature is not a failure: the kernel answers
`IRREGEX_STALE` when its in-process view cannot be trusted for this query, which
means "ask the tier below", and the caller never learns it happened.

  * `native` — loads `libirregex`, probes which symbols this build actually
    exports, and verifies the row-schema digest before any row is believed.
  * `analytic` — the seventeen analytic verbs: parameters lowered once, run
    through `irregex_analytic_run`, rows pulled as a cursor with real batching.
  * `decode` — one schema-driven decoder for every row type (ADR-377).
  * `cold` — the subprocess tier, rebuilding the same rows from the CLI's NDJSON
    so both transports feed one decoder.
  * `shell` / `daemon` — process invocation and the warm resident session.
  * `errors` — the typed failures, including the two the analytic plane adds.
"""

from __future__ import annotations
