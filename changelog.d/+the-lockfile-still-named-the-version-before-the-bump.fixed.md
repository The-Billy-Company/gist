A version bump moved `Cargo.toml` and left the lockfile behind, and `--locked`
is the flag whose whole job is to refuse to fix that. A lockfile records the
version of every package it locks, including the one it sits next to, so the
release bumping the manifest through its `x-release-please-version` annotation
put the two a version apart. `cargo publish --locked` then stopped with "cannot
update the lock file because --locked was passed", which is correct behaviour and
a wedge: nothing about it improves on a retry, so the crate never reaches the
registry no matter how many times the release runs.

`gist` hit it on v1.2.0 with the wheel and the Go module already published, so
the tag existed and the crate did not. The committed lock was stale in the tree
too, which means `cargo build --locked` in `bindings/rust` was already failing
for anyone who tried it.

The publish now re-pins the lock's own version from the manifest beside it
first, hermetically - a `version = "..."` rewrite and nothing else, so no
third-party pin can move and the graph being published is still the one that was
tested, which is the reason `--locked` is there at all. `cargo update
--workspace` was the first attempt and the wrong one: it resolves the whole
graph, so it wants a sibling `irregex` checkout for the `irgx` path dependency
that this job has no reason to make, and relate's v1.1.0 failed exactly there
while `cargo publish --locked` had never needed it.
