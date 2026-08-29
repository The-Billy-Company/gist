- **`cargo publish` reaches crates.io again.** A lockfile records a version for
  every package it resolved, and two of those are ours: `gist-search`, whose
  manifest the release bot bumps and whose lock entry it does not, and `irgx`,
  which moves on irregex's release schedule rather than on this one. Nothing
  rewrote either, and `cargo publish --locked` is the one command that refuses
  to reconcile a stale lock rather than quietly fixing it. So the crates.io leg
  of the release died — v1.2.0 on this crate's own pin, v1.2.2 on the sibling's,
  each time with the wheel and the Go module already out.

  The repair is [`tools/relock.py`](../tools/relock.py), run just before the
  publish. It finds the local packages by walking the manifest graph instead of
  being told their names, reads each declared version off disk, and rewrites
  that one `version = "..."` line in the lock. Nothing is re-resolved and no
  registry is contacted, so no third-party pin can move: what gets published is
  still the graph that was tested, one version number later. A third local
  package added next year is covered the day it exists.
