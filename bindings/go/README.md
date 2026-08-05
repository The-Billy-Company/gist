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

The module path is not itself importable — there is no package at its root.
Import the one you want:

```go
import (
    "github.com/The-Billy-Company/gist/bindings/go/exact"
    "github.com/The-Billy-Company/gist/bindings/go/index"
)
```

The default build is **pure Go and needs no native artifact**. Every verb
answers by running the installed `gist` binary, the transport
`contract/surface.toml` calls authoritative, so a `CGO_ENABLED=0` static image
can import this module unchanged. That binary does have to be on `PATH` (or
`$GIST_BIN`); [the repository](https://github.com/The-Billy-Company/gist) builds
it with `zig build`.

The in-process tier is an accelerator, and it is opt-in:

```bash
zig build                      # mints zig-out/{lib/libgist.dylib,include/gist.h}
go build -tags irgx_ffi ./...
```

This module is nested, so the proxy resolves it by a subdirectory-prefixed tag —
`bindings/go/v1.0.0`, not `v1.0.0`. `go get` handles that for you; it only
matters if you are reading the tag list.

## Layout

| Package           | Concern                                                                              |
| ----------------- | ------------------------------------------------------------------------------------ |
| [`exact`](exact/) | pattern search — `Engine`, `Cursor`, files / count / rank                            |
| [`index`](index/) | artifact lifecycle and readiness                                                     |

Shared types (`Request`, `Match`, analytic params, the row decoder, the fallback
ladder) come from
[`irregex/bindings/go/{analytic,runtime}`](https://github.com/The-Billy-Company/irregex/tree/main/bindings/go).

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
