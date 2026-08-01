A `gist` verb could die of a stack smash purely because the artifact home's path was a certain length.

The session's rendezvous path is `<artifact home>/gistd.sock`, and anything that probes for a resident daemon hands that path to `std.Io.net.UnixAddress`. std publishes one POSIX-wide `max_len` of 108 bytes, but Darwin's `sun_path` holds **104**, and std's POSIX copy takes the length unclamped — only its Windows arm applies a `@min`. So an address of 105–108 bytes passed `init` and was then memcpy'd up to four bytes past a 104-byte `sun_path` sitting on std's own stack, into whatever neighbored the connect helper's frame.

The window is four bytes wide and exact: 104 and below fits, 109 and above `init` refuses. That is why this read as flakiness for months. Whether a run landed in it depended only on how long the artifact home happened to be, so it appeared under a test runner that names temp directories after the test — and never from a shell, where `mktemp` paths are short.

It also never crashed anywhere near the damage. The report we finally chased was a segfault inside an unrelated file read three calls later, dereferencing a pointer whose low bytes were `0x6b636f73` — `"sock"`, the tail of the very path that overflowed.

`conduit/rendezvous.zig` now owns the platform's real capacity, read off `sockaddr.un`'s own `path` field rather than assumed, and every site that turns a path into a socket address goes through it. An address the kernel cannot hold is refused, which the callers already handle as "no daemon is listening there" — true by construction, since nothing can be bound to a path the kernel will not accept.

Two gates, both mutation-proven. The unit test walks every length std would have admitted past the platform bound and pins the refusal (on Linux the two bounds coincide and that span is empty, which is the correct statement there rather than a weaker test). `bindings/python/tests/test_rendezvous.py` runs the real binary across rendezvous lengths 98–115: with the guard removed and the binary rebuilt, exactly 105, 106, 107 and 108 fail and nothing else. It builds its temp home under the shortest writable temp root on purpose — under macOS's default `TMPDIR` there is no room left to construct a 105-byte address, and the suite would have skipped the entire window while reporting itself green.

This is a bug in the Zig standard library that we are guarding around; the upstream fix is for `UnixAddress.max_len` to be per-platform, or for `addressUnixToPosix` to clamp on POSIX as it already does on Windows.
