The Python binding has an import contract: `bindings/python/binding.zone`,
governing `gist-search` the way `charter.zone` governs the Zig side.

This is the one binding in the family with a warm path, so it is the one whose
layering was worth writing down: the index lifecycle below, the facade and its
`exact/` subpackage above as a single unit, tests on top. The cycle is declared
rather than tolerated - `_native` asks `_daemon` whether a request is
FFI-eligible, because that predicate is the daemon protocol's and should have
exactly one definition, and it asks through a deferred in-function import so the
load-time graph stays acyclic.

Needs `zoning` 1.3.1, which is where the `python` dialect and root-anchored
contracts both arrive.
