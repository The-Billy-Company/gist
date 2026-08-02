The distribution is called `gist-search` because the bare name was taken, which
means the name does no discovery work at all - nobody types "gist" looking for a
code searcher. Until now the metadata did not make up for it. The Python package
shipped a one-line summary, no keywords, no classifiers, no README, and no
links, so its PyPI page was going to be a blank card with "Importable Python API
for gist exact search." on it.

It now carries the words the job actually gets searched under: code search,
grep, ripgrep, find in files, trigram index. The summary leads with what it does
rather than with the word "importable", the README opens on indexed code search
with ripgrep semantics instead of on package boundaries, and `rank` gets named
early because it is the one verb with no grep equivalent. The crate got the same
treatment inside its five-keyword budget, plus `readme`, `homepage`,
`repository`, and `documentation`.

The rest of the Python README is unchanged apart from an install section and
links to the three sibling packages.
