A version bump moved `Cargo.toml` and left the lockfile behind, and `--locked`
is the flag whose whole job is to refuse to fix that. A lockfile records the
version of every package it locks, including the one it sits next to, so the
release bumping the manifest through its `x-release-please-version` annotation
put the two a version apart. `cargo publish --locked` then stopped with "cannot
update the lock file because --locked was passed", which is the correct
behaviour and a wedge: nothing about it improves on a retry, so the crate never
reaches the registry no matter how many times the release runs.

`gist` hit it on v1.2.0, with the smoke tests green on all six targets and the
GitHub release already published, so the tag exists and the crate does not. The
committed lock was stale in the tree too, which means `cargo build --locked` in
`bindings/rust` was already failing for anyone who tried it.

The publish now re-pins first, with `cargo update --workspace`. That moves only
the local packages, against the manifests beside them, and leaves every
third-party pin exactly as committed - so the dependency graph being published
is still the one that was tested, which is the reason `--locked` is there.
