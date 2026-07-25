<!--
doc_radar:
  counts:
    - glob: "pkg/kernels/irregex/bindings/go/*/"
      equals: 5
  sentinels:
    - file: contract.go
      contains:
        - "ABIVersion    = 2"
        - "func Verb(op Op) (VerbDef, bool)"
        - "func Schema(id uint32) (SchemaDef, bool)"
        - "func EnumOrdinal(id uint32, label string) (int64, bool)"
    - file: runtime/analytic.go
      contains:
        - "func Run(ctx context.Context, q Query) (*Rows, error)"
    - file: request.go
      contains:
        - "type Request struct"
        - "type Match struct"
-->

# `pkg/kernels/irregex/bindings/go/`

Go binding for [irregex](../../README.md) — Billy's `ripgrep`-parity code-search
kernel and its compression-search sibling. Since ADR-377 it reaches the **whole**
kernel: exact search, the seven kinship verbs, the five retrieval verbs, the four
composed verbs, and the artifact lifecycle.

Lives in **its own `go.mod`** so it is never pulled into the `CGO_ENABLED=0`
static Cloud Run services (backend / gateway / platform — ADR-110). Importing it
is an opt-in to cgo — but no longer a _requirement_ of it: without a library every
verb answers through the certified binary instead.

## Layout

| Package               | Concern                                                                                                                                     |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| root (`irregex`)      | the generated schema table, the mirrored contract constants, `Request`/`Match`, the analytic param families, grade/channel/unit calibration |
| [`runtime`](runtime/) | the transports and the fallback ladder: cgo dispatch, the generic row decoder, the child runner, error mapping                              |
| [`exact`](exact/)     | pattern search — `Engine`, `Cursor`, files / count / rank                                                                                   |
| [`relate`](relate/)   | kinship and retrieval — similar · dups · clusters · echoes · concepts · fragments · distinct · recall · pack · quote · patterns · counts    |
| [`compose`](compose/) | the composed verbs — context · family · provenance · blast                                                                                  |
| [`index`](index/)     | artifact lifecycle and readiness                                                                                                            |

Dependencies flow one way: the root package holds the contract and imports
nothing, `runtime` imports the root, and the four verb packages import `runtime`.
`Engine` and `Cursor` therefore live in `exact` rather than at the root — the root
is the contract, not a facade, because a facade re-exporting `exact` would close
the cycle. `schema_gen.go` stays where its generator writes it, which is what
makes the root package the contract package.

## Using it

```go
import (
    irregex "irregex/bindings/go"
    "irregex/bindings/go/exact"
    "irregex/bindings/go/relate"
)

eng, _ := exact.Open("services/backend")
defer eng.Close()
cur, err := eng.Search(ctx, irregex.Request{Pattern: `func\s+\w+`, IgnoreCase: true})
for cur.Next() { m := cur.Match(); /* … */ }

kin, _ := relate.Over("libs").In(root).Similar(ctx, irregex.Kinship{Target: "pkg/tools/support/scan.py", Top: 5})
```

Each package's README carries its own vocabulary. Two facts hold everywhere:

- **A tier that cannot answer declines, and a declinature is not an error.** A
  stale artifact, a library with no analytic plane, a pattern outside the
  linear-time engine, a `CGO_ENABLED=0` build — each falls through to the child
  process and produces the same rows. Only a real fault is an `error`.
- **Absent is not zero.** Every optional field is read through a presence mask,
  because `distance = 0.0` means _identical_ and a sentinel would erase the
  difference.

## Build and test

```bash
make build-gist    # produces ../../zig-out/{lib/libirregex.a,include/irregex.h}
cd pkg/kernels/irregex/bindings/go
GOWORK=off go test ./...                  # cgo tier + child tier
GOWORK=off CGO_ENABLED=0 go test ./...    # child tier only — a first-class mode
```

Tests use the installed `gist` / `relate` / `irregex` binaries (or `$GIST_BIN` /
`$RELATE_BIN` / `$IRREGEX_BIN`, or `PATH`, or `../../zig-out/bin`) as a
cross-face oracle, and skip cleanly when none resolves. `IRREGEX_NO_FFI=1` forces
the child tier, which is both an operator escape hatch and how the tier-agreement
tests prove the two transports answer alike.
