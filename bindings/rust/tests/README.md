# gist crate tests

Behavioral tests over the certified `gist` binary. Contract parity and the
analytic verb suite live with the crates that own those surfaces
(`irregex` / `relate`).

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
