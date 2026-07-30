//! gist resident session — the O(changed) reconcile resolver.
//!
//! `Delta` turns one drained batch of watcher paths (absolute, as the OS
//! delivered them) into walk-certified verdicts the session can apply to its
//! overlay WITHOUT re-walking the tree: for each path it answers "would the
//! cold path's certified rg-default walk admit this right now?" using the very
//! same `Ignore` machinery (`corpus/tree/ignore.zig`) the walk itself
//! runs — same rule parsing, same precedence, same hidden/`.git` folding — so
//! a scoped reconcile cannot drift from `defaultFileSet`.
//!
//! Fail-closed: `resolve` answers `.needs_full` for anything it cannot prove
//! sound to scope —
//!
//!   - a path it cannot map under the session's roots (or the root itself);
//!   - an ignore-semantics source (`.gitignore`/`.ignore`/`.rgignore`,
//!     the `.git` entry, `.git/info/*`, `.git/commondir`) — editing one can
//!     flip the verdict of ARBITRARY other paths, so only the full walk is
//!     sound.
//!
//! Non-ASCII keys ARE scoped (Workstream D): `realpath` is the canonicalization
//! oracle for both ASCII case AND Unicode normalization aliasing (APFS/HFS+
//! fold NFC/NFD to one on-disk spelling), so a non-ASCII event resolves to a
//! normal `file`/`subtree`/`gone` verdict just like any other. The one residual
//! hazard — a corpus key that is a stale normalization/case TWIN of a path the
//! batch never named, which the ASCII fold in `applyGones`/`applySubtree` can't
//! equate — is swept separately by the session's non-ASCII key re-verification
//! (`keyIsCurrent` over the small set of keys carrying a byte ≥ 0x80), so this
//! resolver models only the direct, canonicalizable verdicts.
//!
//! `.git` INTERNAL churn (`.git/index`, objects, refs — the `git status`
//! heartbeat of a live repo) resolves to `.skip`: those paths are never walked
//! and never feed ignore semantics, so they cost a hash probe instead of a
//! full reconcile.
//!
//! The instance is arena-backed and per-drain: it re-reads the ignore chain
//! from disk each time, so its verdicts are always the tree-now truth (an
//! ignore-file edit both invalidates old verdicts AND `.needs_full`s the
//! drain that saw it).

const std = @import("std");
const fault = @import("../../../fault.zig");
const ignore = @import("../../../corpus/tree/ignore.zig");
const paths = @import("../../../corpus/scope/paths.zig");
const inode = @import("../../../corpus/read/inode.zig");
const Dir = std.Io.Dir;
const realpathAlloc = paths.realpathAlloc;

/// Reading the ignore chain from disk can run out of memory, and this resolver
/// runs inside `irregex_search`'s reconcile — so it RETURNS that rather than
/// exiting the embedding host (ADR-373 law 1). It is not a `.needs_full`:
/// declining to the full walk would only hit the same wall with the fault
/// laundered into a slower path.
const Oom = std.mem.Allocator.Error;

/// `enumerate`'s private control-flow signal: this subtree cannot be enumerated
/// soundly, so nothing short of the full walk may be trusted. It **never leaves
/// the module** — `walkSubtree` converts it at the boundary into
/// `Decline.freshness_unprovable`, which is the same fact `Verdict.needs_full`
/// already carries for `resolve` (ADR-373 law 1: one fact, one channel, and the
/// success position so `try` cannot turn a fallback into an abort).
///
/// Named and non-`pub` on purpose. Spelled inline as `error{NeedFull}!void` in
/// each signature it would be inferred out of the file and owe the global fault
/// taxonomy a member for what is purely this resolver's business.
const Unscoped = error{NeedFull};

/// One resolved watcher path, in KEY SPACE (the exact path-string dialect the
/// session's corpus keys use: `prefix-joined-from-root`, CWD-relative when the
/// session is rootless).
pub const Verdict = union(enum) {
    /// Provably irrelevant to the walked set (e.g. `.git` internals).
    skip,
    /// Cannot be scoped soundly — the caller must run the full walk.
    needs_full,
    /// An admitted regular file: stat/read it through the freshness cursor.
    file: []const u8,
    /// A live directory: enumerate its admitted subtree and diff.
    subtree: []const u8,
    /// Gone from the walked set (deleted, ignored, hidden, or no longer a
    /// regular file): the key — and anything under `key/` — must leave the
    /// corpus if present.
    gone: []const u8,
};

/// One canonical→key-space rewrite: `canon` is the realpath of a served root
/// (the spelling every watcher backend reports events under), `key` is that root
/// as the corpus spells it ("" for the rootless CWD walk).
const Mapping = struct { canon: []const u8, key: []const u8 };

pub const Delta = struct {
    a: std.mem.Allocator,
    io: std.Io,
    ig: ignore.Ignore,
    maps: []const Mapping,
    roots: []const []const u8,
    /// False when the root shape can't be scoped soundly (overlapping roots,
    /// a `.`/trailing-slash root, an unresolvable realpath): the caller falls
    /// back to the full walk, exactly today's behavior.
    enabled: bool,

    /// `a` should be a per-drain arena: every internal allocation (ignore
    /// rules, mappings, verdict strings) lives exactly one batch.
    pub fn init(a: std.mem.Allocator, io: std.Io, roots: []const []const u8) Oom!Delta {
        var self = Delta{
            .a = a,
            .io = io,
            .ig = try ignore.Ignore.init(a, io, .{}, roots),
            .maps = &.{},
            .roots = roots,
            .enabled = false,
        };
        self.maps = buildMappings(a, roots) orelse return self;
        self.enabled = true;
        return self;
    }

    /// Resolve one watcher-delivered absolute path into a key-space verdict.
    /// The returned string is arena-owned and canonically spelled (macOS
    /// `realpath` canonicalizes ASCII case and firmlinks) whenever the path
    /// still exists; a vanished path keeps the event's spelling and is
    /// reconciled case-insensitively by the caller via `keyIsCurrent`.
    pub fn resolve(self: *Delta, abs: []const u8) Oom!Verdict {
        const canon = realpathAlloc(self.a, abs) orelse abs;
        const rel = self.keyFor(canon, false) orelse return .needs_full;
        if (rel.len == 0) return .needs_full; // the walk root itself
        switch (classify(rel)) {
            .semantics => return .needs_full,
            .noise => return .skip,
            .normal => {},
        }
        for (self.roots) |r| if (std.mem.eql(u8, rel, r)) return .needs_full;
        return self.statVerdict(rel);
    }

    /// Would the certified walk, run right now, admit `rel` as a searched
    /// file? (Regular file on disk + every ancestor directory descended + the
    /// leaf not ignored/hidden.) The membership half of the freshness proof —
    /// `.file` — plus the disk-truth verdicts for everything else `rel` may be.
    fn statVerdict(self: *Delta, rel: []const u8) Oom!Verdict {
        // `lstat` mode bits (never following a symlink — the walk treats a
        // symlink as absent), null when the path is gone/unreachable. Rides the
        // shared portable raw-stat shim (`inode.lstatPath`).
        const st = inode.lstatPath(rel) orelse return .{ .gone = rel };
        if (st.kind == .directory) return .{ .subtree = rel };
        if (st.kind != .file) return .{ .gone = rel };
        return if (try self.fileAdmitted(rel)) .{ .file = rel } else .{ .gone = rel };
    }

    /// Is corpus key `rel` still a current, canonically-spelled member of the
    /// walked set? Beyond the membership proof, the kernel's own canonical
    /// spelling (`realpath`) must map back to exactly this key — on a
    /// case-insensitive filesystem a stale spelling (`Lib/x` after a
    /// case-rename to `lib/x`) resolves but is NOT current, and must be
    /// tombstoned so the freshly-read spelling isn't reported twice.
    pub fn keyIsCurrent(self: *Delta, rel: []const u8) Oom!bool {
        if (try self.statVerdict(rel) != .file) return false;
        const canon = realpathAlloc(self.a, rel) orelse return false;
        const back = self.keyFor(canon, false) orelse return false;
        return std.mem.eql(u8, back, rel);
    }

    /// Enumerate every file the certified walk would admit under directory
    /// `rel` right now, into `sink` (arena-owned keys). An inadmissible or
    /// vanished `rel` yields an empty sink (the caller tombstones the scope).
    ///
    /// An unreadable directory **declines** rather than faulting: cold reports
    /// walk errors and exits 2, so a silently gapped subtree may never look
    /// clean, and the sound answer is the full walk. The declinature rides the
    /// success position (ADR-373 law 1) precisely because the tempting `try`
    /// here would abort a reconcile that has a correct slower answer.
    pub fn walkSubtree(self: *Delta, rel: []const u8, sink: *std.StringHashMapUnmanaged(void)) Oom!fault.Answer(void) {
        const scoped: fault.Answer(void) = .{ .got = {} };
        const root = self.rootOf(rel) orelse return .{ .declined = .freshness_unprovable };
        if (!try self.chainAdmitted(root, rel)) return scoped;
        var d = Dir.cwd().openDir(self.io, rel, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return scoped, // vanished since resolve — scope is empty
            else => return .{ .declined = .freshness_unprovable },
        };
        d.close(self.io);
        self.enumerate(rel, sink) catch |e| switch (e) {
            error.NeedFull => return .{ .declined = .freshness_unprovable },
            error.OutOfMemory => |oom| return oom,
        };
        return scoped;
    }

    // ── internals ──

    /// The key-space root governing `rel` ("" for the rootless walk), or null
    /// if `rel` sits under none of them.
    fn rootOf(self: *const Delta, rel: []const u8) ?[]const u8 {
        if (self.roots.len == 0) return "";
        for (self.roots) |r| {
            if (rel.len > r.len and std.mem.startsWith(u8, rel, r) and rel[r.len] == '/') return r;
        }
        return null;
    }

    /// Is every directory on `rel`'s ancestor chain (strictly below `root`,
    /// up to and including `rel`'s parent — or `rel` itself when `thru_self`
    /// callers pass a directory) descended by the walk? Loads each ancestor's
    /// own ignore files in walk order (check the entry against the rules
    /// loaded so far, THEN load its own file before descending), exactly like
    /// `walkDirLinked`. `dir` is the deepest directory to admit.
    fn chainAdmitted(self: *Delta, root: []const u8, dir: []const u8) Oom!bool {
        self.ig.scopeToRoot(root);
        if (root.len != 0) try self.ig.loadDir(root, root); // walkDir's first act per root
        if (dir.len <= root.len) return true; // the root itself: chain is empty
        var i: usize = if (root.len == 0) 0 else root.len + 1;
        while (i <= dir.len) {
            const slash = std.mem.indexOfScalarPos(u8, dir, i, '/') orelse dir.len;
            const prefix = dir[0..slash];
            const base = prefix[i..];
            if (self.ig.shouldSkip(prefix, true, base, false, false)) return false;
            try self.ig.loadDir(prefix, prefix);
            i = slash + 1;
        }
        return true;
    }

    /// The leaf admission test: ancestor chain descended + the file itself not
    /// ignored/hidden. Mirrors the walk's `.file` arm with default `Opts`
    /// (no globs/types, so both whitelist overrides are false).
    fn fileAdmitted(self: *Delta, rel: []const u8) Oom!bool {
        const root = self.rootOf(rel) orelse return false;
        const cut = std.mem.lastIndexOfScalar(u8, rel, '/');
        if (!try self.chainAdmitted(root, if (cut) |s| rel[0..s] else "")) return false;
        const base = if (cut) |s| rel[s + 1 ..] else rel;
        return !self.ig.shouldSkip(rel, false, base, false, false);
    }

    /// The recursive descent of `walkSubtree`: same admission decisions as
    /// `walkDirLinked`'s `.directory`/`.file` arms under default `Opts`
    /// (symlinks and specials are dropped — the default walk never follows).
    fn enumerate(self: *Delta, dir_rel: []const u8, sink: *std.StringHashMapUnmanaged(void)) (Unscoped || Oom)!void {
        var d = Dir.cwd().openDir(self.io, dir_rel, .{ .iterate = true }) catch return error.NeedFull;
        defer d.close(self.io);
        var it = d.iterate();
        while (it.next(self.io) catch return error.NeedFull) |e| {
            const child = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ dir_rel, e.name });
            switch (e.kind) {
                .directory => if (!self.ig.shouldSkip(child, true, e.name, false, false)) {
                    try self.ig.loadDir(child, child);
                    try self.enumerate(child, sink);
                },
                .file => if (!self.ig.shouldSkip(child, false, e.name, false, false)) {
                    try sink.put(self.a, child, {});
                },
                else => {},
            }
        }
    }

    /// Map a watcher path into key space WITHOUT canonicalizing — preserving
    /// the event's own (possibly stale) spelling. ASCII-fold-insensitive on
    /// the root prefix (the kernel may deliver either case shape of a
    /// firmlink/root); null when the path sits under no root or carries
    /// non-ASCII bytes (aliasing unmodeled → caller walks fully). This is the
    /// "which corpus key did this event SPELL" half of a rename: when it
    /// differs from the canonical key, the caller tombstones the raw spelling
    /// unless it is still a current member (`keyIsCurrent`).
    pub fn rawKey(self: *Delta, abs: []const u8) ?[]const u8 {
        return self.keyFor(abs, true);
    }

    /// Rewrite a canonical absolute path into key space via the longest
    /// matching root mapping; null when it sits under no served root. The
    /// shared root-prefix rewrite behind `rawKey` (ASCII-fold prefix
    /// equality) and `resolve`/`keyIsCurrent` (exact prefix equality).
    fn keyFor(self: *const Delta, path: []const u8, comptime fold: bool) ?[]const u8 {
        for (self.maps) |m| {
            const under = path.len > m.canon.len and path[m.canon.len] == '/';
            if (!under and path.len != m.canon.len) continue;
            const head = path[0..m.canon.len];
            // Case-insensitive (ASCII fold) equality, neither side pre-folded.
            const eq = if (fold) std.ascii.eqlIgnoreCase(head, m.canon) else std.mem.eql(u8, head, m.canon);
            if (!eq) continue;
            if (!under) return m.key;
            const suffix = path[m.canon.len + 1 ..];
            if (m.key.len == 0) return suffix;
            return std.fmt.allocPrint(self.a, "{s}/{s}", .{ m.key, suffix }) catch null;
        }
        return null;
    }
};

/// The three path classes `resolve` gates on. Pub for the adversarial suite.
pub const Class = enum { normal, semantics, noise };

/// Classify a key-space path by its components: ignore-rule sources (and the
/// walk-topology-bearing slivers of a `.git` dir) demand the full walk;
/// other `.git` internals are provably outside the walked set.
pub fn classify(rel: []const u8) Class {
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".gitignore") or
            std.mem.eql(u8, comp, ".ignore") or
            std.mem.eql(u8, comp, ".rgignore")) return .semantics;
        if (std.mem.eql(u8, comp, ".git")) {
            const next = it.next() orelse return .semantics; // the `.git` entry itself
            if (std.mem.eql(u8, next, "info") or std.mem.eql(u8, next, "commondir")) return .semantics;
            return .noise;
        }
    }
    return .normal;
}

/// ASCII-lowercased copy (the fold `keyIsCurrent`'s aliasing model uses).
pub fn foldLower(a: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    return std.ascii.lowerString(try a.alloc(u8, s.len), s);
}

/// Does `s`, ASCII-folded, sit at-or-under folded prefix `lower` (component
/// boundary respected)?
pub fn foldUnderLower(s: []const u8, lower: []const u8) bool {
    if (s.len < lower.len or !std.ascii.eqlIgnoreCase(s[0..lower.len], lower)) return false;
    return s.len == lower.len or s[lower.len] == '/';
}

/// Canonical→key mappings for the served roots, or null when the shape is not
/// soundly scopeable: a `.`/empty/trailing-slash root, roots that overlap
/// (even case-insensitively — on a case-insensitive filesystem they alias),
/// or a root whose realpath cannot be resolved.
fn buildMappings(a: std.mem.Allocator, roots: []const []const u8) ?[]const Mapping {
    if (roots.len == 0) {
        const canon = realpathAlloc(a, ".") orelse return null;
        return a.dupe(Mapping, &.{.{ .canon = canon, .key = "" }}) catch null;
    }
    for (roots, 0..) |r, i| {
        if (r.len == 0 or std.mem.eql(u8, r, ".") or r[r.len - 1] == '/') return null;
        for (roots[i + 1 ..]) |s| if (foldOverlap(r, s)) return null;
    }
    const maps = a.alloc(Mapping, roots.len) catch return null;
    for (roots, maps) |r, *m| {
        const canon = realpathAlloc(a, r) orelse return null;
        m.* = .{ .canon = canon, .key = r };
    }
    // Longest canonical prefix first, so nested realpaths (if any survive the
    // overlap gate via symlinks) resolve to the deepest mapping.
    std.mem.sort(Mapping, maps, {}, struct {
        fn longer(_: void, x: Mapping, y: Mapping) bool {
            return x.canon.len > y.canon.len;
        }
    }.longer);
    return maps;
}

/// Case-insensitive component-boundary overlap (equal, or one under the other).
fn foldOverlap(x: []const u8, y: []const u8) bool {
    const short = if (x.len <= y.len) x else y;
    const long = if (x.len <= y.len) y else x;
    return std.ascii.eqlIgnoreCase(short, long[0..short.len]) and
        (long.len == short.len or long[short.len] == '/');
}

test "classify: ignore sources and .git topology demand the walk, internals don't" {
    const t = std.testing;
    try t.expectEqual(Class.semantics, classify(".gitignore"));
    try t.expectEqual(Class.semantics, classify("services/ai/.gitignore"));
    try t.expectEqual(Class.semantics, classify("a/.ignore"));
    try t.expectEqual(Class.semantics, classify("a/.rgignore"));
    try t.expectEqual(Class.semantics, classify(".git"));
    try t.expectEqual(Class.semantics, classify("nested/repo/.git"));
    try t.expectEqual(Class.semantics, classify(".git/info/exclude"));
    try t.expectEqual(Class.semantics, classify(".git/commondir"));
    try t.expectEqual(Class.noise, classify(".git/index.lock"));
    try t.expectEqual(Class.noise, classify(".git/objects/ab/cdef"));
    try t.expectEqual(Class.noise, classify("nested/.git/HEAD"));
    try t.expectEqual(Class.normal, classify("src/exec/session/reconcile/delta.zig"));
    try t.expectEqual(Class.normal, classify("gitignore.md")); // substring, not component
}

test "fold helpers: ASCII aliasing with component boundaries" {
    const t = std.testing;
    try t.expect(foldUnderLower("Foo.TXT", "foo.txt"));
    try t.expect(!foldUnderLower("foo.txt", "foo.txt2"));
    try t.expect(foldUnderLower("Lib/Sub/X.txt", "lib"));
    try t.expect(foldUnderLower("LIB", "lib"));
    try t.expect(!foldUnderLower("library/x", "lib")); // no boundary
}
