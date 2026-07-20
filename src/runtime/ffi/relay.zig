//! Resident-record → C-record translation.
//!
//! The callback boundary owns one reusable submatch buffer. It never owns
//! resident strings and never executes a query; `session.zig` inspects `oom`
//! after the stream halts and maps it to the public status contract.

const std = @import("std");
const contract = @import("contract.zig");
const resident = @import("../session/resident.zig");

const gpa = std.heap.c_allocator;

pub const Relay = struct {
    callback: contract.MatchFn,
    context: ?*anyopaque,
    submatches: std.ArrayList(contract.Submatch) = .empty,
    oom: bool = false,

    pub fn deinit(self: *Relay) void {
        self.submatches.deinit(gpa);
    }

    pub fn emit(self: *Relay, record: resident.MatchRecord) bool {
        if (self.oom) return true;
        self.submatches.clearRetainingCapacity();
        self.submatches.ensureTotalCapacity(gpa, record.spans.len) catch {
            self.oom = true;
            return true;
        };
        for (record.spans) |span| self.submatches.appendAssumeCapacity(.{
            .text = record.text.ptr + span.start,
            .len = span.end - span.start,
            .start = span.start,
            .end = span.end,
        });
        const match = contract.Match{
            .path = record.path.ptr,
            .path_len = record.path.len,
            .line_number = record.line_number,
            .line = record.text.ptr,
            .line_len = record.text.len,
            .submatches = self.submatches.items.ptr,
            .nsubmatches = self.submatches.items.len,
            .kind = @enumFromInt(@intFromEnum(record.kind)),
        };
        return self.callback(self.context, &match) != 0;
    }
};
