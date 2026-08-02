The Python binding's whole `test_cursor` surface — 19 tests — killed the
interpreter outright in a side-by-side dev tree. Not a failure, a SIGSEGV: the
first `Engine.search` went into `gist_search_cursor` and never came back.

The process was mapping two engines. `libgist` links `libirgx` dynamically
and carries a loader-relative rpath, so it binds the copy staged beside itself
— the one gist's own build produced. Importing `irregex` maps one eagerly too,
and its loader resolves the engine out of the `irregex` checkout, on the
deliberate rule that a package's library lives in that package's `zig-out/lib`.
Both rules are right on their own. Together, in a tree where both checkouts are
built, they name two different files: a product configures its dependency
itself, so the sibling's own copy is a different build of the same source. A
handle minted by one engine then gets read by the other's code, which is
undefined behavior rather than a decline — macOS binds two-level, so it never
even reaches the accidental first-wins rescue ELF would give.

The substrate loader can't fix this, because it has no way to know a product is
in the room. So gist names the copy its own library binds, before anything
imports `irregex`. An explicit `$IRGX_LIB` still wins — a caller who names an
engine meant that engine — and an installed prefix, where both libraries sit in
one directory, resolves to the file that loader would have picked anyway.

213 passed.
