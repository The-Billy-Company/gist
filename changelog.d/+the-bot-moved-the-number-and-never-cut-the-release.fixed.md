Three bugs in the release machinery, each of which alone was enough to stop a
release, and together they are why main has said 1.2.0 since August with `v1.1.0`
still the newest tag.

`release-please-config.json` named the package. With `include-component-in-tag`
off, release-please writes a standalone release PR's body with no component in it,
and names the branch `release-please--branches--main` with no component either.
Then, on merge, before it will tag anything, it compares that empty component
against `component || package-name` - so a `package-name` here makes the two
halves of its own bookkeeping disagree permanently. Every merge logged
`PR component: undefined does not match configured component: gist-search` and
returned without creating the tag or the release. That is worse than a missed
release, because it wedges: an untagged merged release PR makes the *next* run
abort before it opens anything, so the queue stops until someone relabels the old
PR by hand.

The fold's guard read the wrong side of the index. towncrier stages its own
edits; it writes the newsfile and retires each fragment through `git add` and
`git rm`, so a working-tree-vs-index diff is quiet the instant it finishes, even
though it just rewrote CHANGELOG.md. The job compared against the index rather
than HEAD, printed `nothing new to fold`, and exited 0 having done nothing. Every
fragment this release was supposed to publish is still sitting in `changelog.d/`.

And the fold only ran on the push where release-please rewrote the PR. The
action sets its `pr` output only when it wrote something, so a `ci`/`docs` commit
carrying a new fragment, which changes no version and therefore no note, left
that output empty, and the job skipped with nothing saying so. The branch is now
resolved from the `autorelease: pending` label instead, which is release-please's
own marker for the PR it is holding open rather than a name guessed from a
convention.

`.release-please-manifest.json` claimed 1.2.0, a release that never happened -
no tag, nothing on crates.io or PyPI, no changelog section. Left alone it would
have made the next release bump *past* a number nobody can install, so it is back
to 1.1.0, the newest version that actually shipped. The next release therefore
re-cuts 1.2.0 with all of the fragments this one was supposed to publish, and the
version already written into `build.zig.zon` on main becomes true rather than
aspirational.

With `always-update` on, the branch is rebuilt on every push while the PR is
open, so the fold recomputes from main rather than appending to whatever the
branch already carries - towncrier treats a second write of the same version as a
hard error, not a no-op.
