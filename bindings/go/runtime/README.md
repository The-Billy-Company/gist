<!--
doc_radar:
  sentinels:
    - file: dispatch.go
      contains:
        - "//go:build cgo"
        - "irregex_analytic_run"
        - "__attribute__((weak))"
    - file: stub.go
      contains:
        - "//go:build !cgo"
    - file: analytic.go
      contains:
        - "func Run(ctx context.Context, q Query) (*Rows, error)"
        - "func Probe() Tier"
        - "IRREGEX_NO_FFI"
    - file: row.go
      contains:
        - "func Assemble(schema uint32, fields []Value) (Row, error)"
        - "func (r *Rows) NextBatch(dst []Row) (int, error)"
        - "func (r *Rows) Stats() Stats"
-->

# `runtime` — the transports and the fallback ladder

Everything that touches the kernel from Go lives here: the cgo declarations, the
analytic dispatch, the generic row decoder, the child-process runner, and the
error mapping that decides which of those answers a query. The verb packages
(`exact`, `relate`, `compose`, `index`) hold vocabulary; this package holds
mechanism.

## The ladder

One verb, two tiers, one answer:

1. **In-process** (`dispatch.go`, `//go:build cgo`) — `irregex_analytic_run`
   against the static library. Preferred, allocation-lean, cancellable.
2. **Child process** (`cold.go` + `plan.go` + `decode.go`) — the certified
   `gist` / `relate` / `irregex` binary, its NDJSON raised back into rows of the
   same schema.

A tier that cannot answer **declines**, and a declinature is not an error:
`IRREGEX_STALE` (the warm artifact cannot serve this query), a library with no
analytic plane, a pattern outside the linear-time engine, and a
`CGO_ENABLED=0` build all fall through to the child and produce the _same_ rows.
Only a genuine fault — a malformed pattern, a canceled context, no binary
anywhere — surfaces as an `error`. `Probe()` reports which tiers this process
actually has; `IRREGEX_NO_FFI=1` forces the child tier, which is how a host keeps
working while a drifted library is rebuilt.

Because the analytic exports are additive, `dispatch.go` gives every analytic
symbol a **weak definition** in its cgo preamble. A library built before the
plane still links, and `irregex_schema_digest()` returning `NULL` is the runtime
probe for "no analytic plane" — an absence, never a failure. When the digest is
present and _disagrees_ with the generated `Digest`, `Run` fails loudly with a
`DriftError` naming the schema that moved rather than mis-decoding rows.

## The decoder

One decoder for all twenty-odd verbs, driven by the generated schema table.

```go
rows, err := runtime.Run(ctx, runtime.Query{Op: irregex.OpDups, Params: k, Roots: []string{"libs"}})
defer rows.Close()

buf := make([]runtime.Row, 64)          // fill a caller slice: no per-row garbage
for {
    n, err := rows.NextBatch(buf)
    if n == 0 || err != nil { break }
    for _, r := range buf[:n] { /* r.Text("left"), r.Float("distance"), … */ }
}
st := rows.Stats()                       // Foreign, Omitted, FilesConsidered, Source
```

`Row` is positional over the schema's declared fields and honors the **presence
mask**: `r.Float("distance")` returns `(0, false)` when the field is absent, which
is a different fact from `(0, true)` — distance zero means _identical_. An enum
resolves to its label through the generated table and an ordinal the contract
does not declare arrives as `Known: false` carrying the raw ordinal, never as a
guess. A `rows:` field recurses into child rows of its own schema.

`Stats` carries what a row cannot: `Foreign` (query fingerprints this corpus has
never seen — "your text isn't in this repo", not "no results") and `Omitted` (a
budget trimmed the tail).
