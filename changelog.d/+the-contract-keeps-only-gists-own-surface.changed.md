`contract/surface.toml` is down to what gist actually authors: `[package]`,
`[transports]`, `[session]` and `[tool_boundary]`.

The row schemas, enums, verb table, params families and producer map that used
to sit here are substrate, not gist's. relate and blast return those same rows
through the same cursor, so declaring them in gist's contract meant two
libraries reading a third's file to learn their own wire shape. They are in
`irregex/contract/analytic.toml` now, beside the generator that lowers them into
every binding. `[compose]` and its verbs went to `blast/contract/compose.toml`,
where the library that answers them lives.

`tools/build_schema_tables.py` left with the tables. `tools/sync_contract.py`
now verifies four contracts rather than three, and the Python and Rust parity
gates resolve `analytic` from `irregex` the same way they already resolved
`engine` and `kinship`. Nothing is vendored; each sibling declares its own and
the mirrors cite them where they live.

The C header's account of what a row means pointed at `contract/surface.toml`,
which no longer declares it; it names `irregex/contract/analytic.toml` now, as
do the binding READMEs and the Python package's Doc Radar sentinels.
