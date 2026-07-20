<!--
doc_radar:
  sentinels:
    - file: irregex.go
      contains:
        - "func Open("
        - "func (e *Engine) Search(ctx context.Context, req Request)"
        - "func (c *Cursor) Next() bool"
        - "func (c *Cursor) All() iter.Seq2[Match, error]"
        - "var ErrUnsupportedPattern"
-->

# `pkg/kernels/irregex/bindings/go/`

Go binding for [GIST](../../README.md), Billy's `ripgrep`-parity code-search
kernel — a cgo wrapper over the **pull-cursor C ABI** (ADR-352) that links the
self-contained `libirregex.a`. Lives in **its own `go.mod`** so it is never pulled
into the `CGO_ENABLED=0` static Cloud Run services (backend / gateway / platform —
ADR-110); importing it is an explicit opt-in to cgo.

## Surface

A warm `Engine` opened over some roots, queried many times, each yielding a pull
`Cursor` you drive scanner-style or range over. Cancellation and deadlines are a
`context.Context` — wired straight through, since the pull model needs no
C-to-Go callback.

```go
import "irregex/bindings/go"

eng, err := irregex.Open("services/backend")   // no roots = the rootless CWD walk
defer eng.Close()

cur, err := eng.Search(ctx, irregex.Request{Pattern: `func\s+\w+`, IgnoreCase: true})
defer cur.Close()

for cur.Next() {                                // scanner style: amortizes the cgo crossing
    m := cur.Match()
    fmt.Printf("%s:%d: %s\n", m.Path, m.LineNumber, m.Text)
}
if err := cur.Err(); err != nil { /* mid-stream failure */ }

for m, err := range cur.All() { /* … */ }       // or range-over-func (Go 1.23+)
```

`Request` carries only match-finding _intent_ the ABI has a field for — `Pattern`,
`Fixed`, `IgnoreCase`/`SmartCase`/`Unicode`, `Word`, `Invert`, `Quiet`,
`Before`/`After`/`Context`, `MaxCount`. Glob/type scoping, multiline, and ranking
stay CLI-only; a query needing them uses the `gist` binary. Records are copied into
Go-owned values as the cursor yields them, so a `Match` outlives both handles.

`ErrUnsupportedPattern` (test with `errors.Is`) wraps a pattern outside the
linear-time engine (a lookaround/backreference) — a value, never a dead process.
A canceled `ctx` surfaces as `ctx.Err()`; every handle has an idempotent `Close`
plus a GC finalizer safety net.

## Build prerequisites

```bash
make build-gist    # produces ../../zig-out/{lib/libirregex.a,include/irregex.h}
cd pkg/kernels/irregex/bindings/go && GOWORK=off CGO_ENABLED=1 go test ./...
```

The `#cgo` directives resolve the static library + header via `${SRCDIR}/../../zig-out`.
The tests use the built `gist` binary (or `$GIST_BIN`, or one on `PATH`) as a
cross-face oracle and skip cleanly when none resolves.
