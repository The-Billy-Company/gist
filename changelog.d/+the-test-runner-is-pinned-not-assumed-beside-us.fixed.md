The test runner is pinned by url and hash instead of assumed to sit beside this
repository.

`.brigade = .{ .path = "../brigade" }` resolves on a machine that happens to have
the sibling checked out, and nowhere else - so a fresh clone, and CI, could not
build this package at all. brigade is a published package now
(github.com/The-Billy-Company/brigade), pinned the way the vendored engines
already were.

The co-developed siblings stay path deps on purpose: those change together with
this repository and a checkout beside it is the point. A test runner does not,
so this repository chooses its version deliberately.
