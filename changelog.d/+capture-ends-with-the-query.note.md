1.3.2 fixes Windows captures that could wait ten minutes after a search had
already finished. A detached resident daemon now inherits only its own NUL
streams, and the native capture check verifies that queries return while the
daemon stays alive.

This patch also updates Rust and the GitHub Actions dependencies used to build
and validate the release.
