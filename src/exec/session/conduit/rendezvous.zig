//! Where a client and a resident daemon agree to meet: the filesystem path
//! behind the session socket, bounded by what the kernel can actually hold.
//!
//! One job, and it exists because the standard library gets this wrong on
//! Darwin (see `address`). Everything in this package that turns a path into a
//! socket address comes through here, so the platform's real limit is stated
//! once and no call site has to remember it.

const std = @import("std");
const builtin = @import("builtin");

/// The kernel's real capacity for a rendezvous path, read off the very struct
/// the kernel is handed rather than assumed: `sun_path` is 108 bytes on Linux
/// and 104 on Darwin and the BSDs. Derived, so a new target inherits its own
/// number instead of someone else's.
pub const max_path = switch (builtin.os.tag) {
    // std's Windows arm clamps the copy itself, and there is no `sun_path` to
    // read; take std's bound there rather than invent a second one.
    .windows => std.Io.net.UnixAddress.max_len,
    else => @typeInfo(@FieldType(std.posix.sockaddr.un, "path")).array.len,
};

/// `std.Io.net.UnixAddress.init`, bounded by what this kernel can actually hold.
///
/// std publishes one POSIX-wide `max_len` of 108, and its POSIX copy takes the
/// length unclamped — only the Windows arm applies a `@min`. So on Darwin a
/// 105–108 byte path is accepted by `init` and then memcpy'd up to four bytes
/// past a 104-byte `sun_path`, which is a *stack* buffer inside std's connect
/// helper. The write lands in whatever neighbors that frame, so the process
/// dies later and somewhere unrelated: this surfaced as a segfault inside a
/// file read three calls away, dereferencing a pointer whose low bytes spelled
/// "sock" — the tail of the rendezvous path. Bound it before std sees it.
///
/// The window is narrow and exact, which is why it read as flakiness for so
/// long: 104 and below fits, 109 and above `init` refuses, and only the four
/// lengths between corrupt memory. Whether a run lands there depends on how
/// long the artifact home's path happens to be — which is why it appeared under
/// a test runner that names its temp directories after the test, and never from
/// a shell.
pub fn address(path: []const u8) error{NameTooLong}!std.Io.net.UnixAddress {
    if (path.len > max_path) return error.NameTooLong;
    return std.Io.net.UnixAddress.init(path);
}

test "a path the kernel cannot hold is refused rather than truncated" {
    const t = std.testing;
    var buf: [std.Io.net.UnixAddress.max_len + 8]u8 = undefined;
    @memset(&buf, 'x');
    // Exactly full is legal: `sun_path` need not be NUL-terminated when the
    // address length accounts for every byte.
    try t.expect((try address(buf[0..max_path])).path.len == max_path);
    // Every length std would have admitted past that point is the corrupting
    // window. On Linux the two bounds coincide and this loop is empty, which is
    // the correct statement there rather than a weaker test.
    var len: usize = max_path + 1;
    while (len <= std.Io.net.UnixAddress.max_len) : (len += 1) {
        try t.expectError(error.NameTooLong, address(buf[0..len]));
    }
    // Beyond std's own bound both agree, so the refusal must survive there too.
    try t.expectError(error.NameTooLong, address(buf[0 .. std.Io.net.UnixAddress.max_len + 1]));
}
