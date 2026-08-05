// Standalone Go module — intentionally NOT in any parent workspace.
//
// `go get` and `go build` work with no native artifact: the default build is
// pure Go and answers every verb by running the installed `gist` binary, the
// transport the contract calls authoritative. Nothing here needs cgo, so a
// static CGO_ENABLED=0 image can import it.
//
// The in-process tier is the accelerator, and it is opt-in. It links
// `libgist` and `libirgx`, so it needs `zig build` to have produced
// `zig-out/{lib,include}` first — then build `-tags irgx_ffi`. A module
// fetched into the read-only module cache has no such artifact, which is
// exactly why the tag exists.
//
// The shared contract and runtime live in the irregex module; this module is
// search only (exact + index).
module github.com/The-Billy-Company/gist/bindings/go

go 1.24

toolchain go1.26.5

// The substrate is required at its published version, with no `replace`. A
// `replace` in a dependency's go.mod is ignored by whoever imports it, so one
// here would have meant every consumer trying to fetch a v0.0.0 that does not
// exist. Cross-repo work uses a local `go.work` (gitignored), which is the
// mechanism that is allowed to override a published version.
require github.com/The-Billy-Company/irregex/bindings/go v1.0.0
