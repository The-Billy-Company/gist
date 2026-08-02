The warm-vs-cold parity tests asserted a cross-file record order neither tier
promises. The warm engine canonicalizes to a `pathLess` total order; the cold
walk emits in the filesystem's `readdir` order. On a machine where `readdir`
comes out sorted the two agree by accident, which is why this passed on macOS
and on the x86 box and failed on CI. `test_cursor` now pins the cold walk with
the documented `--sort path`, and the three `test_ffi_parity` sites that forgot
the file's own `_by_file` grouping use it. Every field of every record is still
compared; only the free inter-file order is no longer asserted.
