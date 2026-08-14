The GitHub Release page now carries the changelog section it names. Two
changelogs were produced per release and only one of them was towncrier's:
`skip-changelog` hands `CHANGELOG.md` to the fragments, but that key governs
the *file*, and composing the release **body** is a separate path inside
release-please that kept running off conventional-commit subjects. So the page
people land on was assembled from commit subjects while the notes someone
wrote sat in the changelog - irregex v2.1.1 published two lines against a
folded section of a hundred and ten, because eleven of its thirteen commits
were `ci:` or `docs:` and both are hidden. A `notes` job now posts the folded
`## [X.Y.Z]` section over that body on tag, waiting for the release to exist
rather than assuming it already does, and truncating at a whole bullet under
GitHub's 125,000-character body ceiling rather than failing on a tag that is
already immutable.
