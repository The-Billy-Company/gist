`libirgx.a` was copied into the install prefix with `cp
../irregex/zig-out/lib/libirgx.a`, which reads a different build than the one
gist is being compiled against. Under `-Dtarget=x86_64-linux-gnu` that put this
laptop's Mach-O archive into a Linux prefix, where the symbols still carried
their leading underscores and nothing could link against it - and even natively
it needed someone to have run `zig build` in the sibling checkout first, at
whatever optimize mode they happened to pick.

The reason it was a `cp` was real: the engine's archive is an install-file
product of the irregex package rather than a named artifact, so
`dep.artifact("irgx")` cannot see it. It is now published over there as a named
lazy path and taken from the dependency graph, so it is built to order for this
target.

The ELF `libgist.a` also stops registering a second build artifact named
`gist`. The dylib already owns that name, and a duplicate makes a dependent's
`dep.artifact("gist")` ambiguous enough to panic the build runner - in the
DEPENDENT, never here, and only on the arm macOS does not take, so it would
have stayed invisible on a laptop while no Zig consumer could build on Linux.
Both arms install the archive as a file now, the way the macOS arm already did
for its own alignment reasons.
