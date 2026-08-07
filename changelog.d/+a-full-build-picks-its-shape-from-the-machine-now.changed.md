`gist index` decides whether to hold the corpus or stream it, from the machine
rather than from a preference.

`irregex` now offers a build that never holds the corpus: a census of paths and
sizes, and each body read back when the pass that needs it reaches it. It costs
4.1x less memory on llvm-project and 1.7x more wall, and neither of those is the
interesting number on its own — which one matters depends entirely on how big
the tree is relative to the machine looking at it.

So the choice is made per build. `full` estimates the held peak from the corpus
the last build published — the content shard IS that corpus concatenated, so its
size is the answer, and erring high biases toward streaming — and holds only if
that estimate fits in an eighth of physical memory. Above the line it streams.
With no shard to ask, which is the first build in a fresh artifact directory, it
streams: a build that cannot know how big the tree is should not be the one to
discover it by holding all of it.

An eighth is deliberate. Holding is faster, and on ordinary trees nothing about
it is objectionable, so the line is not "is streaming cheaper" but "is this
build about to take a rude share of a machine someone is working in". On the
128 GiB host this was measured on, llvm-project's 1926 MiB corpus is held (8.2 s,
2464 MiB peak) and a corpus four times larger would not be.

`GIST_STREAM=1` and `GIST_NO_STREAM=1` pin it either way, which is what a
benchmark comparing peak RSS against `csearch` or `zoekt` needs: the honest
number for a shape is the one measured with that shape forced, not whichever one
the host happened to choose.

The streamed path falls open to the held one on any failure before publication —
a census that cannot be taken, or a block builder that runs out of memory, costs
a cheaper build and never the index. Past publication there is nothing to fall
back to and both paths fail the same way.

Two things that wanted the corpus now ride along with the pass that already has
it. The crest sieve stops being its own phase — `GIST_TRACE=index` reports
`trigram build + crest` as one lap on the streamed path — and the build records
each doc's real length for the content shard's offset catalog, which is the only
figure that catalog can honestly be built from once the sizes came from an
earlier walk.

PROVEN IDENTICAL: over llvm-project, a held and a streamed build publish the same
`index.gist` (161,773,006 bytes), `crest.bin` (8,405,376) and `paths.list`
(9,107,770), byte for byte. `content.shard` (2,030,371,064) and `tree.map` agree
on every byte of catalog, paths, and bodies, differing only in the 8-byte anchor
and the 32-byte seal over it — the same two fields that differ between two runs
of one binary.
