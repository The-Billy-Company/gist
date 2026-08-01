Three composed-face tests in the Go binding still named the scope they search
with the monorepo path this package was extracted from, so in the extracted repo
they searched a directory that does not exist.

The blast test failed outright, which is how this was noticed. The two pack
tests were worse: an empty scope yields no picks, and "no picks" reads as a
clean answer rather than as a test that never ran. They now derive the scope
from the tree - the kernel is the nearest ancestor holding a `build.zig`, the
binding is this package's own directory - and both resolve correctly whether
the kernel sits at a repo root or nested under `pkg/kernels/irregex`, which
is the same dual-layout rule the cold-binary probe already followed.

The containment assertion was rewritten to compare resolved paths rather than a
string prefix, so it stays meaningful when the scope is the repo root.
