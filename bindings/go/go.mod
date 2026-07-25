// Standalone Go module — intentionally NOT in any parent workspace.
//
// The Cloud Run images for backend / gateway / platform are built with
// CGO_ENABLED=0 (ADR-110). This module links the native libirregex via cgo, so
// importing it from any of those services would break the static-link contract.
// Keep it isolated so only explicit cgo-tolerant consumers (offline tooling,
// benchmarks, one-shot indexers) pull it in. It links the self-contained
// `libirregex.a`, so it needs `make build-gist` (or `make install-gist`) to have
// produced `pkg/kernels/irregex/zig-out/{lib,include}` first.
module irregex/bindings/go

go 1.26.3

toolchain go1.26.4
