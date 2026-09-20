Neither entry here touches search. Both are the machinery around it, and both
hid the same way: by failing somewhere nobody reads.

One ended a release job with `FAILED open or read`, which looks like an
integrity stop and was a path bug, so two releases in a row told you to download
a binary they had not attached. The other leaked a process-table entry for every
daemon that lost the spawn race - invisible in any output, and worth exactly as
much as the number of agents searching at once.

This release also carries the engine's stdin fix: a search reading from a pipe
nobody is writing to now falls through to the tree in two seconds instead of
hanging forever. That one lands through `irregex`, and its notes are on that
release.
