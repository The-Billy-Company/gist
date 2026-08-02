`bench/conformance/gates/parity/type_union_parity.sh` - a permanent guard that
every `-t` named on the line reaches the answer, with ripgrep as the oracle.

It exists because a real bug got through: a `--type-add` name selected with
`-t` was routed into the `-g` include set, which ANDs against the built-in
types rather than joining them, so one custom type silently voided every other
type on the line (fixed in irregex, `Builder.addType`). Each half was
individually correct - built-ins union with built-ins, a custom type alone
matches rg exactly - so only the mix diverged, and no existing case asked for
the mix.

The gate checks per case that gist's file set is byte-identical to rg's; that
the mixed answer contains each part it was built from and is strictly larger
than both; that `-T <custom>` subtracts exactly what `-t <custom>` selected;
and that a custom `-t` still respects `.gitignore`, since only `-g` may
un-ignore.

It synthesizes its own corpus (go, py, rust, ts, tsx, plus a gitignored file)
instead of reading whatever tree it runs in. gist's own checkout is pure Zig,
so the interesting cases would have matched nothing and passed as vacuously
equal; the non-vacuity floors now have something to stand on, and the run is
the same run on every machine.
