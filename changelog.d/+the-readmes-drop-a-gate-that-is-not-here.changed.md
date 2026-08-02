Thirty-seven READMEs carried a `doc_radar:` block - YAML frontmatter on most, an
HTML comment on the rest - declaring path, count, and sentinel assertions for a
freshness gate that lives in the monorepo this package was split out of. That
gate was never ported here, so every one of those blocks was inert. On the
Python binding's README it was also the first thing a PyPI reader would meet,
where the renderer turns a YAML preamble into a horizontal rule followed by a
heading made of raw YAML. They are gone, and the prose below each is untouched.

One comment in `bench/conformance/gates/parity/patterns_corpus_parity.sh` cited
the corpora README's sentinel as the only thing coupling that gate's torture
slate to the generator that plants it. The sentinel never ran, so the comment
now says plainly that nothing enforces the pair and a rename has to land in both
files at once.
