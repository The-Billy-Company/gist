//! The shape the answer takes — decided once, before anything prints.
//!
//! `intent.zig` holds what was asked; this holds what comes back. The two are
//! deliberately separate concepts: a dozen presentation flags argue over one
//! question ("is this run answering with file content, a path list, a tally, or
//! a JSON stream?"), and that argument has exactly one right answer per run.
//!
//! ripgrep settles it with a single `Mode` under a last-wins rule and treats
//! every *other* presentation flag (`-o`, `--passthru`, `--vimgrep`,
//! `--heading`, `--column`, …) as an orthogonal printer option that never
//! competes for the mode slot. gist used to model all of them as co-equal
//! booleans on `Opts` and re-derive the precedence inside each emit dispatcher —
//! `grid.zig` and `multibuf.zig` each owned a private `and !o.count_only and
//! !o.files_only …` ladder. Two ladders, one contract, no compiler holding them
//! to it: they drifted. An ordered-pair differential sweep against rg (every
//! shaping flag crossed with every other, rg as the oracle) found the drift as
//! ~18 interaction divergences, worst around `--heading` and `--vimgrep`.
//!
//! So the precedence lives here, once, and printers consume the verdict instead
//! of re-litigating it. Mutually exclusive modes become unrepresentable rather
//! than merely discouraged: there is no state in which `-l` and `-c` are both
//! "on", because there is only one field.

const std = @import("std");

/// How precisely each row names WHERE its match is — the second decision this
/// file settles, and one with the same failure mode as `Mode`.
///
/// `-n`/`-N` and `--column`/`--no-column` are explicit; `--column` and
/// `--vimgrep` also *imply* line numbers, and `--vimgrep` implies a column.
/// gist used to fire those implications the instant it read the flag, writing
/// straight into the booleans, on the theory (stated in `grammar.zig`) that a
/// later `-N` could then override them "matching rg's left-to-right
/// resolution". It doesn't: rg keeps the explicit answers as `Option<bool>`
/// and applies the implications *afterwards*, so an explicit `-N` wins no
/// matter which side of `--vimgrep` it lands on. Writing eagerly gets the
/// order-dependence exactly backwards, and only the half where the negation
/// happens to come last looks correct:
///
///     rg --vimgrep -N ⇒ path:col:text     gist agreed
///     rg -N --vimgrep ⇒ path:col:text     gist printed the line number
///     rg --column --no-column ⇒ text      gist kept the implied line number
///     rg --no-column --vimgrep ⇒ path:line:text   gist printed a column too
///
/// Holding the explicit answers as null-until-asked and resolving once makes
/// the order-dependence disappear, because an implication can no longer
/// overwrite an answer the user actually gave.
///
/// The `terminal` argument below is the last party to be asked, and only ever
/// about a question still unanswered: rg reads a human-facing stdout as a
/// standing request for the grouped, numbered layout, the same way it reads it
/// as a request for color. Keeping that inside this type means a destination
/// can never outrank a flag — `--no-heading` and `-N` mean what they say on a
/// terminal — and a pipe, which answers `terminal = false`, keeps the exact
/// bytes ripgrep would have written.
pub const Locus = struct {
    /// `-n` / `-N` if either was passed, else null.
    line: ?bool = null,
    /// `--column` / `--no-column` if either was passed, else null.
    column: ?bool = null,
    /// `--heading` / `--no-heading` if either was passed, else null. A heading
    /// is a location answer like the other two — it decides whether a row names
    /// its file in the prefix or inherits it from the title above the group.
    heading: ?bool = null,

    /// Does each row carry a column? Only `--vimgrep` implies one. No terminal
    /// argument: a column is a parseable coordinate, not a reading aid, and rg
    /// does not offer one just because a human is watching.
    pub fn columns(self: Locus, vimgrep: bool) bool {
        return self.column orelse vimgrep;
    }

    /// Does each row carry a line number? `--vimgrep` implies one outright —
    /// `--no-column --vimgrep` still numbers its lines, since a vimgrep row
    /// without one would name no location at all. `--column` implies one only
    /// while the column survives, so `--column --no-column` implies nothing.
    pub fn lines(self: Locus, vimgrep: bool, terminal: bool) bool {
        return self.line orelse (vimgrep or terminal or (self.column orelse false));
    }

    /// Are matches grouped under a filename title? Nothing implies this but the
    /// destination: piped output keeps the `path:line:` prefix every downstream
    /// parser expects, and a terminal gets the grouping a human can skim.
    pub fn headings(self: Locus, terminal: bool) bool {
        return self.heading orelse terminal;
    }
};

/// `-w` and `-x` are one choice, not two flags: rg holds a single
/// `Option<BoundaryMode>`, so the last spelling wins and `-x -w` is a word
/// match. As independent bools, whichever the matcher tested first won
/// instead, making the pair order-blind in the wrong direction.
pub const Boundary = enum { word, line };

/// The one answer shape a run resolves to. The first six search file contents;
/// `files`/`types` answer from the walk alone and need no pattern.
pub const Mode = enum {
    /// The default: matching lines, with whatever framing the printer options ask for.
    standard,
    files_with_matches, // -l/--files-with-matches
    files_without_match, // --files-without-match
    count, // -c/--count (matching LINES per file)
    count_matches, // --count-matches (match SPANS per file)
    json, // --json (a JSON Lines event stream)
    files, // --files (list what would be searched)
    types, // --type-list (dump type definitions)

    /// Does this mode read file contents at all? `files`/`types` answer from
    /// the walk, which is why they need no pattern (`Opts.noPattern`).
    pub fn searching(self: Mode) bool {
        return switch (self) {
            .files, .types => false,
            else => true,
        };
    }

    /// Fold a newly-seen mode flag into the mode resolved so far: the last one
    /// on the argv wins, with no exceptions.
    ///
    /// ripgrep's `Mode::update` carries a comment claiming a search mode cannot
    /// displace a non-search one — "so for example, `--files -l` will still be
    /// `Mode::Files`". Its *observable behavior* disagrees, and behavior is the
    /// oracle here. The decisive case is a pattern that matches nothing, which
    /// is the only way to tell the two readings apart (on a matching pattern
    /// both print the same path):
    ///
    ///     rg --files -l zzz a.txt   ⇒  (nothing)      -l won, not --files
    ///     rg --files -c zzz a.txt   ⇒  (nothing)      -c won
    ///     rg -l --files zzz a.txt   ⇒  a.txt          --files won, being last
    ///
    /// Plain last-wins explains every observation; the documented exception
    /// explains none of them. Encoding the comment instead of the behavior
    /// would have shipped a divergence no fixture with a matching pattern
    /// could ever have caught.
    pub fn update(self: Mode, new: Mode) Mode {
        _ = self;
        return new;
    }

    /// The two corrections ripgrep applies after the last mode flag is read,
    /// because they depend on flags that are not themselves modes:
    ///
    ///  * `--count-matches -v` degrades to `-c`. An inverted line matched
    ///    nothing, so it has no spans to total; counting lines is the only
    ///    coherent reading.
    ///  * `-c -o` promotes to `--count-matches`. Asking for the matches
    ///    themselves and then counting means counting spans, not lines.
    ///
    /// Order matters and they do not compose: each arm returns, so `-c -o -v`
    /// promotes once and stops rather than ping-ponging back to `count`.
    pub fn settle(self: Mode, invert: bool, only_matching: bool) Mode {
        return switch (self) {
            .count_matches => if (invert) .count else self,
            .count => if (only_matching) .count_matches else self,
            else => self,
        };
    }

    /// The compact per-file ENUMERATION shapes: one short line per file — a
    /// path or a tally — never file content. A partial answer here is
    /// misleading (on the unordered parallel engine a soft-cap cut yields a
    /// nondeterministic SUBSET run-to-run), so these are exempt from the soft
    /// context cap. The content shapes keep it: their volume is why it exists.
    pub fn enumerates(self: Mode) bool {
        return switch (self) {
            .files_with_matches, .files_without_match, .count, .count_matches, .files => true,
            .standard, .json, .types => false,
        };
    }

    /// The one shape that prints file CONTENT inside gist's framing — path
    /// prefixes, line numbers, headings, context windows, separators. Every
    /// other mode prints a bare path, a tally, or its own self-framed JSON, and
    /// so takes none of that chrome.
    ///
    /// This predicate is why the chrome decisions stopped drifting: `heading`
    /// and `join_groups` used to be spelled as a hand-written pile of `and
    /// !o.count_only and !o.count_matches and !o.files_only …`, and the serial
    /// engine's pile and the parallel engine's pile did not list the same
    /// modes — so `--heading` behaved differently depending on which engine a
    /// query happened to dispatch to.
    pub fn frames(self: Mode) bool {
        return self == .standard;
    }

    /// Emits one `[path:]N` tally per file (`-c`, `--count-matches`).
    pub fn counting(self: Mode) bool {
        return self == .count or self == .count_matches;
    }

    /// The two modes whose entire answer is a per-file yes/no, rendered as a
    /// bare path. `--files` is deliberately NOT one of them: it prints paths
    /// too, but never asks the pattern anything, so the walk can skip reading.
    pub fn pathPerFile(self: Mode) bool {
        return self == .files_with_matches or self == .files_without_match;
    }

    /// Reports on files that did NOT match, so the per-file verdict inverts and
    /// a zero-match file is the interesting one.
    pub fn negated(self: Mode) bool {
        return self == .files_without_match;
    }
};

test "an explicit -N or --no-column outranks an implication, from either side" {
    const t = std.testing;
    const off: Locus = .{ .line = false };
    try t.expect(!off.lines(true, false)); // -N --vimgrep and --vimgrep -N alike
    try t.expect(!(Locus{ .line = false, .column = true }).lines(false, false)); // -N --column
    // --column --no-column: the column is gone, so it implies no line number.
    try t.expect(!(Locus{ .column = false }).lines(false, false));
    try t.expect(!(Locus{ .column = false }).columns(false));
    // …but --vimgrep numbers its lines even with the column explicitly off.
    try t.expect((Locus{ .column = false }).lines(true, false));
    try t.expect(!(Locus{ .column = false }).columns(true));
    // Bare implications still fire.
    try t.expect((Locus{ .column = true }).lines(false, false));
    try t.expect((Locus{}).lines(true, false) and (Locus{}).columns(true));
    // Nothing asked, nothing implied.
    try t.expect(!(Locus{}).lines(false, false) and !(Locus{}).columns(false));
}

test "a terminal answers only what argv left unanswered" {
    const t = std.testing;
    // Silence + a human watching: rg's grouped, numbered layout.
    try t.expect((Locus{}).lines(false, true) and (Locus{}).headings(true));
    // The same silence into a pipe is ripgrep's byte contract — neither.
    try t.expect(!(Locus{}).lines(false, false) and !(Locus{}).headings(false));
    // A destination is the LAST party asked, never the loudest: `-N` and
    // `--no-heading` mean what they say on a terminal, in either order (the
    // answer is recorded, so there is no order for it to depend on).
    try t.expect(!(Locus{ .line = false }).lines(false, true));
    try t.expect(!(Locus{ .heading = false }).headings(true));
    // …and spelling them ON still works where nothing would have implied them.
    try t.expect((Locus{ .line = true }).lines(false, false));
    try t.expect((Locus{ .heading = true }).headings(false));
    // A column is a coordinate, not a reading aid: no terminal implies one.
    try t.expect(!(Locus{}).columns(false));
}

test "the last mode flag on the argv wins" {
    const t = std.testing;
    var m: Mode = .standard;
    for ([_]Mode{ .files_with_matches, .count, .count_matches, .json }) |new| m = m.update(new);
    try t.expectEqual(Mode.json, m);
    try t.expectEqual(Mode.count, Mode.json.update(.count));
}

test "a walk mode neither outranks nor is outranked — it just takes its turn" {
    const t = std.testing;
    // The case rg's own comment gets wrong: `--files -l` resolves to `-l`.
    try t.expectEqual(Mode.files_with_matches, Mode.files.update(.files_with_matches));
    try t.expectEqual(Mode.count, Mode.files.update(.count));
    // …and reversed, `--files` wins by being last.
    try t.expectEqual(Mode.files, Mode.files_with_matches.update(.files));
    try t.expectEqual(Mode.files, Mode.types.update(.files));
}

test "settle rewrites the count modes against -v and -o" {
    const t = std.testing;
    try t.expectEqual(Mode.count, Mode.count_matches.settle(true, false));
    try t.expectEqual(Mode.count_matches, Mode.count.settle(false, true));
    // `-c -v` has no span reading to promote to, so it stays a line count.
    try t.expectEqual(Mode.count, Mode.count.settle(true, false));
    // Non-count modes are untouched by either flag.
    try t.expectEqual(Mode.standard, Mode.standard.settle(true, true));
    try t.expectEqual(Mode.files_with_matches, Mode.files_with_matches.settle(true, true));
}

test "settle promotes at most once" {
    const t = std.testing;
    // `-c -o -v`: -o promotes to count_matches, and that verdict is final —
    // the -v arm must not fire on the freshly-promoted value.
    try t.expectEqual(Mode.count_matches, Mode.count.settle(true, true));
}

test "shape predicates partition the modes" {
    const t = std.testing;
    for (std.enums.values(Mode)) |m| {
        // A path verdict and a tally are disjoint, and both are enumerations.
        try t.expect(!(m.pathPerFile() and m.counting()));
        if (m.pathPerFile() or m.counting()) try t.expect(m.enumerates());
        // Only a searching mode can report on content, counts, or a verdict.
        if (!m.searching()) try t.expect(!m.counting() and !m.pathPerFile());
        // Exactly one mode frames content; it is never an enumeration.
        if (m.frames()) try t.expect(!m.enumerates());
    }
    try t.expect(Mode.files_without_match.negated());
    try t.expect(!Mode.files_with_matches.negated());
}
