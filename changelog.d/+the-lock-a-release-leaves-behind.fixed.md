- **`cargo publish` reaches crates.io again.** The last three releases all
  tagged, built, and shipped the wheel and the Go module, and all three left
  crates.io on 1.1.0 — each dying at a different step of the same knot.

  A lockfile records a version for every package it resolved, and two of those
  are ours: `gist-search`, whose manifest the release bot bumps and whose lock
  entry it does not, and `irgx`, which moves on irregex's release schedule
  rather than on this one. `cargo publish --locked` is the one command that
  refuses a stale lock instead of quietly reconciling it, so v1.2.0 died on this
  crate's own pin. The fix for that knew one package by name, so v1.2.2 died on
  the sibling's. And in between, v1.2.1 died on the rewrite itself: having
  edited `Cargo.lock` to make `--locked` true, the checkout was no longer clean,
  and cargo refuses to publish an uncommitted tree.

  So both halves are answered. `tools/relock.py` finds the
  local packages by walking the manifest graph instead of being told their
  names, reads each declared version off disk, and rewrites that one
  `version = "..."` line — a third local package added next year is covered the
  day it exists. Nothing is re-resolved and no registry is contacted, so no
  third-party pin can move. And the publish now pairs `--locked` with
  `--allow-dirty`, which read like a contradiction and are not: the graph must
  already be the one that was tested, and the single file that makes that true
  is allowed to be the one this step just wrote.
