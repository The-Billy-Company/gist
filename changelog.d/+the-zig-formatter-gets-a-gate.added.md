Zig is the language this package is written in and it was the only one here whose
formatter nothing checked. Rust already got `cargo fmt --check` and `cargo clippy
-D warnings` on every push in the `rust` job; `zig fmt` was on the honour system.
irregex, relate and blast each grew a `fmt` job for this already, so gist was the
last one running without.

The drift this catches is not the kind you spot in a diff. `zig fmt` pads a
column-aligned multiline array literal into a grid, so a rename that shortens the
widest cell leaves every row beneath it one space too wide, in files nobody
edited. That deserves a red X that says "formatting" rather than one buried at
the bottom of a build log, which is why it is its own job: folding it into
`engine` would run it once per host for a verdict that cannot vary by host.

The file set comes out of git rather than being written down, and this package is
a good argument for why. The obvious hand-written list is `src/ bench/` - which
would silently skip `build.zig` sitting at the repository root, and `tools/`
looks like it would hold Zig and holds only Python, so a list naming it would
check a directory with nothing in it while missing a real file. `git ls-files -co
--exclude-standard '*.zig'` is every Zig file the repository owns; what it leaves
out is exactly the ignored trees (`zig-out/`, `.zig-cache/`, and the fetched
`zig-pkg/`, which parks a whole `build.zig` of its own), and those are named in
`.gitignore` where someone can review them.

It needs no sibling checkout, unlike every build job in this file, because it
reads files instead of configuring a build - so it is also the cheapest job here.

I watched it fail before believing it: 50 files check clean today, a deliberately
mis-padded grid literal dropped at the repository root takes it to exit 1 with
the offending file named, and deleting that file puts it back to 50 clean. The
enumeration picking up a brand-new root-level file is the same thing the
hand-written list would have missed.
