Nothing was checking the news fragments, and the way that fails is nastier than
it sounds. `towncrier build --draft` does not complain about a filename it cannot
parse; it just does not treat it as a fragment. So a file typed `.fixd.md`
instead of `.fixed.md` renders nothing, exits 0, and stays invisible until
somebody notices the entry missing from a release - by which point the fragment
is buried among the sixty others in the directory.

I checked whether `--draft` on its own was the right gate before writing one, and
it is not. Against the real fragment set it is completely blind: a typo'd type, a
file with no type at all, a wrong-cased `.Fixed.md`, and an empty type all give
exit 0 with stdout byte-identical to a clean run and nothing on stderr. Adding
`--draft` alone would have been a green tick over exactly the defect it was
supposed to catch, which is worse than no job because it reads as coverage.

The strictness has to come from `ignore` in `towncrier.toml`. Setting that key -
even to an empty list - flips towncrier from skipping unparseable filenames to
failing on them, with a message naming the file and telling you to whitelist it
if it was deliberate. That is the right place for it: the fragment grammar stays
in towncrier's hands instead of being re-spelled in a filename parser here, the
same reason the formatter's file set comes from `git ls-files` rather than a path
list. It also means a contributor running `towncrier build --draft` locally now
gets the identical error CI does, which is the part a CI-only check would have
missed.

`towncrier check` is deliberately not what this runs - that verb asks whether a
branch added a fragment, which is a contribution policy and a different argument.
This job only asks whether the fragments that exist are well-formed.

There is also a guard against the job passing over nothing, in the same spirit as
the formatter's "found no .zig files": a misconfigured `directory` renders "No
significant changes." and exits 0, so the job fails if fragments are sitting on
disk while towncrier reports none. It is conditioned on fragments actually
existing, so the honest empty draft right after a release still passes.

Proven the whole way round: green on the real tree, exit 1 naming the file when I
drop a `.fixd.md` into a faithful copy, green again once it is removed, and exit 1
on the vacuous-green case when the fragment directory is pointed somewhere empty.
