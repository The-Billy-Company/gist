Towncrier ran with `wrap = true`, which is right for one-line release notes and
wrong for the multi-paragraph Markdown the fragments here actually are. It
reflows each entry as one flat block, which loses a fenced code sample's fence,
turns a hanging `-` at the end of a wrapped line into a setext heading, and can
split an inline code span across a paragraph break. Off, the fragment's own
layout survives and towncrier only indents it.

`changelog.d` also had no README, so folding a release emptied the directory and
git stopped tracking it - the next `towncrier create` would have been writing
into a path that no longer existed in a fresh clone. It has one now, saying what
a fragment is and that its layout is preserved.

`version_parity.py` gained the skip its sibling in `irregex` needed: release
notes name versions and the `x-release-please-version` marker as their subject
matter, so a line-level "marker plus a number" heuristic reads them as stale
mirrors. They are also the one file the release bot must never rewrite, since a
past release's number is history rather than a copy of the current one.
