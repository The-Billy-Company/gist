Every package index this project publishes to now shows the repository's own
`README.md` as the project's page, rather than the short one kept beside each
binding. PyPI and crates.io are where most people meet this project first, and
they were being shown a page about the Python binding's verbs - not the indexed code-search kernel underneath them.

The README could not simply be pointed at, because a relative link resolves
against whatever page displays it. `src/surface/face/gist/README.md` is correct on GitHub and a 404
under `pypi.org/project/gist-search/`. crates.io is the worse of the two: it rewrites
relative links against the crate's own subdirectory, so the same path becomes a
well-formed URL into `bindings/rust/` pointing at a file that was never there,
and nothing looks broken.

So `tools/registry_readme.py` is now the one rewriter both ends share. It
absolutizes every relative target against the `repository` URL the manifest
already declares, in the form that serves what the target is - `raw` for an
image, `tree` or `blob` chosen by what the path is on disk - and a target the
repository does not contain fails the build instead of publishing a dead link.
GitHub's `> [!NOTE]` alert, which renders as literal text anywhere else, is
lowered to a bold lead line. Headings need no help: both renderers rewrite
in-document anchors to match the ids they mint, so the table of contents arrives
intact.

Python gets it through a Hatchling metadata hook, so the corrected page exists
only inside the artifact. Cargo has no metadata hook, so `readme` now points at
a gitignored `bindings/rust/PROJECT_README.md` that the same tool mints at
package time - `cargo package` fails loudly if it was never generated, and
`cargo build` never reads it. Both indexes end up with a byte-identical page.

An sdist is the one artifact with no repository above it, so it carries the
corrected README beside the sources and a source build reads that, rather than
being asked for a file the archive does not contain.

Go needed no rewriting - pkg.go.dev renders the README at the module root and
resolves its links against the repository - but a dead one there is still a dead
link on the module's landing page, and a Go module has no build step to catch
it. `--check` now proves those targets resolve too, on every commit.

The README stays written for the repository it lives in.
