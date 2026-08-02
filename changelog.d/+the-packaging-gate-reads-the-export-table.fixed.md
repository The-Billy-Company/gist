The packaging gate now reads libgist's export table instead of hiding a file and
watching what happens.

The invariant `build.zig` states is about names: libgist links libirgx so that it
does not restate `irgx_*`, which is what lets a host load libgist and librelate
together and still see one engine ABI. The gate used to check that by staging both
libraries, deleting the substrate, and requiring the load to fail. That is a proxy,
and it turns out to be a proxy for the build machine rather than for the invariant -
Zig records the dependency's cache directory as a runtime search path, and
`ZIG_LOCAL_CACHE_DIR` makes that path absolute on CI while it stays relative on a
dev machine. An absolute one resolves the deleted library straight back out of the
build cache, so the check asserted the invariant locally and nothing at all on
Linux CI, where it had been failing.

It reads `nm` now, which answers the actual question. Deliberately not `dlsym`: a
handle resolves its dependencies too, so asking a loaded libgist for
`irgx_engine_open` succeeds by finding libirgx's copy - the very thing under test.
Three gates replace the one: libgist exports none of the substrate's names, it
carries a loader-relative search path (the property that makes the shipped shape
loadable, previously indistinguishable from a build-cache path that happened to
resolve), and the same probe run over libirgx proves it can see an engine
vocabulary when one is really there.

What is deliberately not asserted is that libgist records libirgx as a needed
dependency. That record is the linker's decision rather than this repository's:
ELF drops an `--as-needed` library that no undefined symbol needs, so a product
whose statically linked Zig already satisfies everything records nothing, while
Mach-O keeps the entry regardless. The sibling products disagree on exactly that
line today from identical link calls, which is the proof it was never a contract.
Absent redefinition is what makes the vocabulary single; the dependency table only
ever explained it, and it is reported in the failure message for that reason.

Nothing in the build changed - the boundary was already sound. Each product
statically links the engine's Zig code, because that is what linking a Zig module
means, and the FFI layer allocates through `std.heap.c_allocator`, so a row minted
inside one copy and freed inside the other crosses one process-wide malloc heap.
