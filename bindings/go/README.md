# `bindings/go/`

Go binding for [gist](../../README.md) — search a tree. Exact pattern search and
the warm-artifact lifecycle; nothing else. Kinship lives in the relate module,
composed verbs in the blast module, and the shared contract/runtime in irregex.

Lives in **its own `go.mod`**, so importing it never drags unrelated product
faces into a consumer that only wants search.

## Install

```bash
go get github.com/The-Billy-Company/gist/bindings/go
```

That is the whole story: the default build is **pure Go and needs no native
artifact**. Every verb answers by running the installed `gist` binary, the
transport `contract/surface.toml` calls authoritative, so a `CGO_ENABLED=0`
static image can import this module unchanged.

The in-process tier is an accelerator, and it is opt-in:

```bash
zig build                      # mints zig-out/{lib/libgist.dylib,include/gist.h}
go build -tags irgx_ffi ./...
```

This module is nested, so its release tags carry the subdirectory prefix —
`bindings/go/v0.1.0`, not `v0.1.0`.

## Layout

| Package           | Concern                                                                              |
| ----------------- | ------------------------------------------------------------------------------------ |
| [`exact`](exact/) | pattern search — `Engine`, `Cursor`, files / count / rank                            |
| [`index`](index/) | artifact lifecycle and readiness                                                     |

Shared types (`Request`, `Match`, analytic params, the row decoder, the fallback
ladder) come from
[`irregex/bindings/go/{analytic,runtime}`](../../../irregex/bindings/go/).

## Using it

```go
import (
    "github.com/The-Billy-Company/irregex/bindings/go/analytic"
    "github.com/The-Billy-Company/gist/bindings/go/exact"
)

eng, _ := exact.Open("src")
defer eng.Close()
cur, err := eng.Search(ctx, analytic.Request{Pattern: `func\s+\w+`, IgnoreCase: true})
for cur.Next() { m := cur.Match(); /* … */ }
```

## Build and test

```bash
zig build
cd bindings/go
GOWORK=off go test ./...                       # child tier — the default
GOWORK=off go test -tags irgx_ffi ./...        # cgo tier + child tier
GOWORK=off CGO_ENABLED=0 go test ./...         # child tier with cgo off
```
