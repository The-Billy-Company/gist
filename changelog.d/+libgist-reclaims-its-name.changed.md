`libgist` is the search product's C ABI again. The artifact, header, and
session symbols were still named for the engine library after the ecosystem
split (`libirregex`, `include/irregex.h`, `irregex_open` / `_search` /
`_analytic_run`). They are now `libgist`, `include/gist.h`, and `gist_*`.
Substrate status codes, the fault pull, and the `irregex_rows_*` cursor stay
in `libirregex`; `gist_run` returns that cursor on purpose. The product
stops shipping duplicate `ffi/{rows,schema.gen}.zig` and the `Rows` walker —
those live in `@import("irregex").ffi`.
