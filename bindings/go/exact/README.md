<!--
doc_radar:
  sentinels:
    - file: engine.go
      contains:
        - "func Open(roots ...string) (*Engine, error)"
        - "func (e *Engine) Search(ctx context.Context, req analytic.Request) (*Cursor, error)"
        - "func (e *Engine) Files(ctx context.Context, req analytic.Request) ([]string, error)"
        - "func (e *Engine) Count(ctx context.Context, req analytic.Request) (int, error)"
        - "func (e *Engine) Rank(ctx context.Context, req analytic.Request, top int) ([]Ranked, error)"
        - "func (c *Cursor) All() iter.Seq2[analytic.Match, error]"
-->

# `exact` — pattern search

Where is this exact pattern? A warm `Engine` opened over some roots, queried many
times, each query yielding a pull `Cursor` you drive scanner-style or range over.

```go
eng, _ := exact.Open("src/server/api")
defer eng.Close()

cur, err := eng.Search(ctx, analytic.Request{Pattern: `func\s+\w+`, IgnoreCase: true})
defer cur.Close()
for cur.Next() {
    m := cur.Match()
    fmt.Printf("%s:%d: %s\n", m.Path, m.LineNumber, m.Text)
}
if err := cur.Err(); err != nil { /* mid-stream fault */ }

for m, err := range cur.All() { /* … */ }   // or range-over-func
```

`NextBatch(dst []analytic.Match)` fills a caller slice for the allocation-sensitive
path; `Next` is that with a 64-record buffer of its own. Records are copied into
Go-owned values as they are yielded, so a `Match` outlives both handles.

Beyond the record stream, three presentation-shaped questions the engine answers
better than a caller re-deriving them: `Files` (paths with at least one match),
`Count` (matching lines), and `Rank` — the definition-first view where a symbol's
definition outranks its call sites and generated files sink below authored code.

## Tiers

The in-process library is preferred and the `gist` child is the fallback, chosen
per query rather than per engine. A pattern outside the linear-time engine (a
lookaround, a backreference) is a **declinature**, not a failure: the child
answers it through PCRE2 and the caller sees rows either way.
`errors.Is(err, runtime.ErrUnsupportedPattern)` only surfaces when _no_ tier can.
An engine with no library at all — a `CGO_ENABLED=0` host — is fully functional.

The warm corpus stands up lazily on first search, so `In(dir)` has already had its
say about which tree relative roots name.
