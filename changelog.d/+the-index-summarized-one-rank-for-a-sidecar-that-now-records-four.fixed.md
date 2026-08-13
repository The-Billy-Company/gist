The engine's CREST sidecar went to v6, and its rows widened from a 48-lane q=1
vector to a 192-lane q=4 spectrum. This package is what writes those rows - both
build paths do, the held one and the streamed one - so `gist` stopped compiling
against the sibling the moment that landed; `persistIndexAndPaths` takes
`?[]const crest.Spectrum` now.

The held path was reaching for the right function's neighbor: `sidecar.build` is
the q=1 table the resident session keeps for live documents, and
`sidecar.buildSpectra` is the parallel q=4 pass the persisted artifact wants. The
streamed path summarizes each doc inline while the trigram pass still has its
bytes, and it asks for `crest.spectrum(bytes, max_rank)` rather than
`crest.crest(bytes)`.

Both paths have to agree on the rank, and that is the part worth saying out loud:
the sidecar header records ONE q for the whole file, and `persist` stamps
`max_rank` unconditionally. A streamed index carrying rank-zero-only rows under a
q=4 header would meet a rank-1 demand with a zero, fall short of it, and prune a
document that matches. That is a wrong answer, not a slow one, which is why the
streamed path summarizes at the same rank the held path does rather than at the
cheaper default.

No new guard: this package's build jobs already check out `irregex` at its
default branch, so the sibling's main is what every push here compiles against.
