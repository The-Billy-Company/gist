// Standalone Go module — intentionally NOT in any parent workspace.
//
// `go get` and `go build` work with no native artifact: the default build is
// pure Go and answers every verb by running the installed `gist` binary, the
// transport the contract calls authoritative. Nothing here needs cgo, so a
// static CGO_ENABLED=0 image can import it.
//
// The in-process tier is the accelerator, and it is opt-in. It links
// `libgist` and `libirregex`, so it needs `zig build` to have produced
// `zig-out/{lib,include}` first — then build `-tags irregex_ffi`. A module
// fetched into the read-only module cache has no such artifact, which is
// exactly why the tag exists.
//
// The shared contract and runtime live in the irregex module; this module is
// search only (exact + index).
module github.com/The-Billy-Company/gist/bindings/go

go 1.24

toolchain go1.26.5

require github.com/The-Billy-Company/irregex/bindings/go v0.0.0

replace github.com/The-Billy-Company/irregex/bindings/go => ../../../irregex/bindings/go
