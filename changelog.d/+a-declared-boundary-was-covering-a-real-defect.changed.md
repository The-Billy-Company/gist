`--files-without-match` is no longer a declared boundary in the ripgrep-parity
harness, because there is nothing left to declare.

The entry said rg contradicted itself: over a tree holding a walked NUL-bearing
file it exits 0 while printing no path, so gist's exit 1 was recorded as the
coherent reading of a mode whose code means "a path was listed". That reading was
wrong. rg's success predicate here is `match_count == 0` - "some file's search
found no match" - and an abandoned binary search found none. gist now answers the
same question (fixed in irregex), so the difference the boundary excused does not
occur.

That matters more than tidiness: `surface.py`'s table is imported by both the flag
probe lane and the differential fuzzer, so as long as the entry stood, a
regression back to exit 1 would have been scored `declared` in both and waved
through. The `silent0` residual it was the only user of is gone with it.

411/411 mined cases still pass in both the parallel and serial lanes.
