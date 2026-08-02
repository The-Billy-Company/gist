# gist crate tests

Behavioral tests over the certified `gist` binary, plus the parity gate on the
one contract this repository authors. The substrate's own mirrors — row schemas,
analytic verbs, grade bands — are gated in the crates that own them (`irregex` /
`relate`).

## Contract (needs no binary)

- `contract.rs` — `gist::contract` does not drift from `contract/surface.toml`:
  the published `dist` / `import` names and the tool-boundary aliases and routing
  keys. Fails closed on a contract it cannot read.

## Cold subprocess (needs `gist` binary)

- `search.rs` — structured matches, rg-parity discovery, typed pattern errors
- `aggregate.rs` — `tally` / `summary` over synthetic and live matches
- `rank.rs` — definition-first `--rank` view against a throwaway index

## Warm path (needs `gist serve` or `--features native`)

- `session.rs` — resident-session client: eligibility, fail-open, warm≡cold
- `cursor.rs` — in-process `Engine`/`Cursor` (`--features native`)

```bash
cd bindings/rust && cargo test                   # cold (skips without gist/rg)
cd bindings/rust && cargo test --features native # + in-process cursor
```
