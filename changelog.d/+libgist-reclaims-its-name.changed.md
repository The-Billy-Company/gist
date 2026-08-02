`libgist` is the search product's C ABI again. The artifact, header, and
session symbols were still named for the engine library after the ecosystem
split (`libirregex`, an engine-named header, and an `irregex`-prefixed
`open` / `search` / `analytic_run` triad). They are now `libgist`,
`include/gist.h`, and `gist_*`.
Substrate status codes, the fault pull, and the `irgx_rows_*` cursor stay
in `libirgx`; `gist_run` returns that cursor on purpose. The product
stops shipping duplicate `ffi/{rows,schema.gen}.zig` and the `Rows` walker —
those live in `@import("irregex").ffi`.
