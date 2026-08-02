The changelog's own header claimed gist ships the `relate` binary. It hasn't
since relate moved to its own package - `build.zig` only declares the `gist`
executable, and says so in its module doc. The header now describes what gist
actually is: indexed code search, plus the chassis module relate and blast ride.
