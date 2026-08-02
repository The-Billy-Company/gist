The Go index suite had a test split in two on a false premise, and the half that
was supposed to run everywhere could not run anywhere.

The reasoning was that reading a fresh artifact home should be gist's own code,
so it was pulled out of the relate-dependent test to stop it skipping on public
CI. It is not gist's own code. `Corpus.Atlas` reads `relate status --json` -
relate produces the artifacts *and* the document reporting whether they are
ready - so the extracted half failed outright rather than passing:

```text
--- FAIL: TestAtlasReportsNothingReadyWhenNothingIsBuilt
    atlas: irregex: no gist/relate/blast binary found: RELATE_BIN is unset,
    relate is not on PATH, and no build exists at any of: ...
```

The two halves are back together, with a skip that names the real reason. What
changed is that the skip is no longer where the story ends: relate's CI builds
both sides and drives this suite with the binary present, so the assertion gist
cannot check is checked by the repository that can. Verified on x86_64 Linux in
both shapes - green with relate absent, and a genuine pass with it present.

Every other missing-binary arm in the module stays fatal. Those all resolve
`gist`, which CI builds, so a miss there is a broken environment rather than an
absent capability.
