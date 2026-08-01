Every in-process parity test in the Python binding — 73 of them, the whole
`test_ffi_parity` and `test_cursor` surface — was skipping with
`libirregex/cffi unavailable`, and a suite that reports 119 passed / 73 skipped
reads as green. Two causes, both artifacts of the repo split.

`cffi` is deliberately not a runtime dependency: the in-process tier is an
accelerator and fails open to the subprocess without it, which is what keeps the
shipped wheel pure-Python. Inside billy it arrived anyway, transitively, from the
sibling cffi kernels; a standalone checkout has no such sibling, so the tier went
dark everywhere at once. It is now a test-only dependency, which is where it
always belonged — the runtime contract is unchanged.

With the tier awake, 19 of those tests failed: the cursor drove
`gist_engine_open` / `gist_cancel_*`, and the engine had moved down into
libirregex as `irregex_engine_*`. Retargeted onto the substrate's spelling; the
symbols resolve through libgist's own handle because libgist links libirregex by
rpath, so the engine a cursor reads is the one the binding opened — no second
implementation, which is the whole reason the engine moved.

192 passed, nothing skipped.
