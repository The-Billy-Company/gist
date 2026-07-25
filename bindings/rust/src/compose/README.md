---
doc_radar:
  sentinels:
    - description: "the four composed verbs of ADR-367"
      file: pkg/kernels/irregex/bindings/rust/src/compose/mod.rs
      contains: ["pub fn context", "pub fn family", "pub fn provenance", "pub fn blast"]
    - description: "context and family require an explicit scope"
      file: pkg/kernels/irregex/bindings/rust/src/compose/verbs.rs
      contains: ["everywhere", "Unrepresentable"]
---

# `compose/` — the questions that need both engines at once

`exact` narrows by pattern. `relate` reasons by resemblance. A composed verb
(ADR-367) runs them **in one pass, inside one candidate set**: the exact engine
decides which files are even eligible, and the compression engine then reasons
only within that subset. Hand-piping `gist -l` into `relate` throws away the
match information between the steps and pays whole-corpus statistical noise on
the second half; these verbs do not.

The exact and statistical scores stay in separate fields on the row. They are
never fused into one number, because a caller has no way to un-mix them
afterwards and the two are not commensurable.

| Verb         | The question                                                                                                    |
| ------------ | --------------------------------------------------------------------------------------------------------------- |
| `context`    | Among the files that actually match these intents, which non-redundant set should I read?                       |
| `family`     | Among the files matching this symbol, which are forks or renamed twins of each other?                           |
| `provenance` | Where is this pasted text really from — re-verified against the source's _current_ bytes?                       |
| `blast`      | If I change this symbol, what moves? Dependents, dependencies, twins, ripple, and the comments that mention it. |

## Scope is mandatory, and that is a feature

`context` and `family` refuse to run without either explicit roots or
`.everywhere()`.
A composed query is expensive enough that silently sweeping `vendor/` is a
mistake worth making impossible rather than documenting. `blast` is corpus-wide
by default because its whole job is _"what did I not think of"_, and narrowing it
by hand is exactly how a caller misses the thing.

`provenance` re-reads each candidate source before attributing a phrase to it, so
an answer cannot outlive the bytes it was derived from — a quote whose source
file has since changed simply does not surface.

## When to edit

Composition happens in the kernel, not here. A new composed verb is a contract
change plus a generator run; this module only names parameters that already
exist in `[analytic.params]` and translates them for the subprocess rung.
