Adopted the substrate's shortened caller-facing spelling. The engine library's C
ABI prefix is `irgx_` rather than `irregex_`, its installed header is `irgx.h`,
its Python package imports as `irgx`, and its Rust lib is `irgx`. Every seam
this repository reaches through it moved with it: the cgo preamble and cursor in
the Go binding, the `extern "C"` block and `use` paths in the Rust binding, the
cffi cursor in the Python binding, `include/gist.h`, and the FFI prose in
`src/`. The project, the repository, the PyPI and crates.io identities, and the
`@import("irregex")` Zig alias are all unchanged - what shortened is the
identifier a caller types, not what the thing is called. gist's own `gist_*`
symbols were never in scope.
