//! gist bench — the single, shared probe registry for the Certificate of
//! Optimality. Layer A (`certify.zig`, microscopic cycles/byte) and Layer D
//! (`../lowerbound/lowerbound.zig`, the algorithmic floor) must speak about
//! *exactly* the same eleven regex classes for the certificate to line up
//! class-for-class across layers — so both `@import` this file instead of
//! keeping their own copy. Before this file existed the two arrays were
//! independently hand-maintained "keep in sync" copies (a real drift risk
//! flagged during Layer D's build); importing one definition removes the
//! risk structurally instead of documenting it as acceptable.
//!
//! `../certify/certify.sh` (the macroscopic bash race) necessarily keeps its
//! own copy of these eleven rows — a shell script can't `@import` Zig data —
//! but it is a single, already-documented cross-language boundary, not
//! open-ended drift between two Zig files.

/// One probe per *regex class* gist competes on (the "every type of
/// operation" axis). Each names the class so the certificate maps 1:1 to the
/// claim under test.
pub const Kind = enum { literal, regex };
pub const Probe = struct { class: []const u8, kind: Kind, pattern: []const u8 };

pub const probes = [_]Probe{
    .{ .class = "literal-rare", .kind = .literal, .pattern = "pgxpool" },
    .{ .class = "literal-dotted", .kind = .literal, .pattern = "context.Context" },
    .{ .class = "literal-common", .kind = .literal, .pattern = "func" },
    .{ .class = "literal-punct2", .kind = .literal, .pattern = "})" },
    .{ .class = "regex-decl", .kind = .regex, .pattern = "func\\s+\\w+\\(" },
    .{ .class = "regex-dotted", .kind = .regex, .pattern = "pgxpool\\.\\w+" },
    .{ .class = "regex-anchored", .kind = .regex, .pattern = "^func\\s" },
    .{ .class = "regex-classcount", .kind = .regex, .pattern = "[0-9a-f]{8}-[0-9a-f]{4}" },
    .{ .class = "regex-alternation", .kind = .regex, .pattern = "return|continue|break" },
    .{ .class = "regex-dense-scan", .kind = .regex, .pattern = "\\w{3,8}" },
    .{ .class = "regex-eol", .kind = .regex, .pattern = ";$" },
};
