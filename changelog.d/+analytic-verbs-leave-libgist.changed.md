`gist_run` keeps only `rank`. Kinship, retrieval, and the multi-pattern sweep
moved to `librelate` (`relate_run`); the composed verbs moved to `libblast`
(`blast_run`). A host that wants kinship no longer links the search library
to get it — each producer returns the same `irgx_rows *` walked by
`libirgx`. Op numbers are unchanged, so a stored verb id still means the
same thing ecosystem-wide.
