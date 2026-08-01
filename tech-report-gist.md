### Tech Report Gist

## What is irregex?

Irregex is the tool I developed at the Billy Company to replace ripgrep as our default grep tool. It is a modern regular expression engine that is designed to be accurate without compromising performance when large amount of agents are writing simultaneously to one tree.

It is written in Zig, and it is a major improvement in the code search field in terms of performance but also in terms of ergonomics. 

## Installation

You build it, and that is one command rather than an apology for missing
packaging: Zig ships its own cross-compiler, and the vendored C rides along
with the same invocation.

```
$ zig build -Doptimize=ReleaseFast   # Zig 0.16.0
$ zig-out/bin/gist index             # ~3s, and now every query is warm
```

Nothing else is required. There is no configure step, no system PCRE2 to
hunt down, no cross toolchain to install even when the target is not the
machine you are sitting at - [Layer H](#evidence) builds twenty-two of them
from one laptop with zero toolchains present.

The packaged paths are reserved rather than live, and I would rather say so
than send you to a 404. As of this writing
`[The-Billy-Company/irregex](https://github.com/The-Billy-Company/irregex)`
holds the name and nothing else, it publishes no release binaries, and
`pip install irregex` lands a 3 KB placeholder at 0.1.0 while the real C-ABI
bindings sit at 0.2.0 unpublished. When the engine goes out it goes out there
and under that name. Until then the tree is the distribution.

## Tour

This is the short version. `gist --help` and `gist --schema` are the exhaustive one.

### The `gist` CLI

`gist` is the search face and the one you will live in. No verb, no setup:

```
$ gist "hello world"
```

Recursion is the default. So is obeying `.gitignore`, so is stepping around hidden files and binary data, and matches land on stdout as `path:line:match`. 

The reflexes carry over whole: `-i` for case insensitive, `-S` for smart case, `-w` for whole words, `-v` to invert, `-C3` when you need the neighborhood, `-l` for filenames only, `-c` for counts, `-F` when the pattern is punctuation rather than regex. The `-u` family runs the other way, each one buying back a category the defaults threw away: ignore files, then hidden files, then binary data.

That is the floor, and I will come back to how strictly it is held.

**Ranked search.** Sometimes I want the best hit, not every hit. `--rank` leaves the pattern and path semantics untouched and changes only the shape of the answer, fusing lexical density, declaration confidence, match rarity, path shallowness, and a demotion for generated files:

```
$ gist 'func NewServer' --rank
 1. src/server/server.go:42       [def]  ×1  func NewServer(port int) *Server {
 2. src/server/server_test.go:18  [use]  ×6  srv := NewServer(0)
```

Definition first, call sites after, codegen sunk. It is heuristic text ranking rather than a symbol table, and it is worth every bit of that distinction.

**Docs or code.** The other native axis is one `-t` cannot express. `-t` answers "which language is this," and nobody asks that. The question people actually ask is whether they are reading the paper trail or the implementation, so that is its own partition: `docs`, `code`, `data`, total and disjoint over every path, with `--no-` complements that are exact.

```
$ gist SessionStore --docs      # only prose: what was written ABOUT it
$ gist SessionStore --no-docs   # only the implementation and its payload
$ gist retry_budget --data      # only config: json, yaml, toml, lockfiles
```

**Scope.** Underneath those, the ordinary narrowing. Positional paths shrink the walk; globs and types shrink it further.

```
$ gist session src/server       # explicit scope
$ gist session -g '*.sql'       # one glob
$ gist session -g '!vendor/**'  # negate it and the glob subtracts instead
$ gist session -tgo -tpy        # type filters compose; -T subtracts one
```

`gist --type-list` prints the registry - a strict superset of ripgrep's, so anything parsing rg's format parses this - and `--type-add 'notes:docs/**'` invents a type for the length of one run.

**Pattern semantics, and backtracking.** The default engine is a linear Thompson/Pike matcher in the RE2 tradition, so a pathological pattern cannot detonate on you, and Unicode is on by default: folding, classes, `\p{Han}` properties, and word boundaries all reason over codepoints rather than bytes. Lookaround and backreferences are not linearly expressible, so they get a vendored PCRE2 10.47 with JIT.

```
$ gist 'foo(?=bar)' -P             # PCRE2 semantics, on demand
$ gist 'foo(?=bar)' --engine auto  # linear first, escalate only if the pattern needs it
```

Both backends ride the same trigram prefilter, which makes this the only *indexed* PCRE search I am aware of: the lookaround still skips the files that provably cannot match. `--no-unicode`, or a leading `(?-u)`, drops to byte and ASCII semantics when that is what you meant.

**The index is optional.** Everything above works with no setup at all; without an index gist walks the live tree and reaches the same answer, just slower. With one, it skips the files that cannot contain the query's required trigrams and checks every survivor against current bytes.

```
$ gist index           # build/refresh the persisted trigram index, ~3s
$ gist status --json   # is one ready, how fresh, how big
$ gist serve           # the resident warm session, though it self-spawns
$ gist codex count 'literal'   # exact corpus-wide count, zero source I/O
```

The rule underneath all of it: the tree tells the truth. An accelerator may decline, and it does, constantly - a changed file, a stale anchor, a doubtful watcher - but it may never invent a file set or hand back a stale line. `--no-index` forces the pure live walk, and it is the differential oracle the indexed path is tested against.

**Unix philosophy.** Results go to stdout as rg-shaped bytes. Everything else - timings, freshness notes, no-match suggestions, budget warnings - goes to stderr, so a pipe never sees a word gist said about itself. Exit codes are honest, and they are ripgrep's:

```
$ gist zzz src/ ; echo $?        # 1 - a clean search, no match. an answer.
$ gist --nonsense foo ; echo $?  # 2 - not an answer
```

A flag gist does not recognize, or a pattern the chosen engine cannot express, is an error. It is never a convincing empty result, because a silent zero is the one failure an agent cannot detect.

Output shape follows the reader, not a config file. A terminal gets ripgrep's grouped layout, filename heading with numbered rows beneath it, plus clickable OSC-8 links straight into your editor; a pipe gets plain bytes and no links. `--plain` forces the piped posture onto a terminal so an interactive run reproduces a captured one, and `-p` forces the human one the other way.

**Parity is a constraint, not a resemblance.** Which brings me back to that floor. 186 of 186 documented ripgrep flags conform, and that number is measured on every run against a live `rg` oracle rather than asserted in a README. Where gist does diverge it is an improvement or it is a bug; there is no third category, and the eight cases get their own section below.

`gist --schema` emits the whole flag surface as JSON, generated from the same catalog argv is parsed with, so a binary cannot drift from its own documentation. `gist --generate man` and `--generate complete-{bash,zsh,fish,powershell}` render that catalog for humans, and `gist config` reports what is steering the run and from which file.

## How does search work?

My predecessor Andrew Gallant has an amazing description of how this machinery
works, in the
*[Anatomy of a grep](https://burntsushi.net/ripgrep/#anatomy-of-a-grep)*
section of his 2016 post announcing ripgrep's benchmarks. 

It is, in my opinion,
the easiest to read and by far the most useful for this discussion. What follows
is a quick and less comprehensive summary; his remains the truer vivisection,
and I gleaned mine from it.

A grep does four things in order. 

- It decides **which files** to look at. 
- It gets **their bytes** into memory. 
- It decides **which of those bytes match**. 
- Then it **prints**, in a shape somebody downstream can use. 

That is the whole program, and every tool in the field is an argument about which of those four steps you  
are allowed to skip.

The step people underrate is the third one, because a grep is not a regex
library wearing a command line. 

Gallant makes this point directly: a grep is
*line oriented*, and line orientation buys optimizations a general regex engine
cannot make. 

Mike Haertel's [account of why GNU grep is
fast](https://lists.freebsd.org/pipermail/freebsd-current/2010-August/019310.html)
is the classic statement of it, and his first trick is a refusal: GNU grep is
fast because it **avoids looking at every input byte**. 

It runs Boyer-Moore with
an unrolled inner loop, spends fewer than three instructions on the bytes it
does look at, and - the part that surprises people - deliberately does not split
the input into lines, because finding the newlines would itself require touching
every byte. It reads raw into a big buffer, skips through it, and goes looking
for the bounding newlines only once it already has a match. 

Haertel's summary of the whole discipline: "the key to making programs fast is to make them do practically nothing."

Hold onto that, because it generalizes past bytes. There are only two costs in
search - the files you open and the bytes you scan - and every serious tool of
the last fifty years is a position on which of the two it refuses to pay. The
history is the story of that refusal getting more sophisticated.

## A Quick History and Introduction



### The algebra came first

Search of this kind is downstream of a piece of pure mathematics. In a 1951
RAND memorandum published in *Automata Studies* in 1956, Stephen Kleene
described the "regular events" a finite-state machine can recognize and gave
them an algebra: concatenation, alternation, and the closure that carries his
name. 

Rabin and Scott then proved in 1959 that letting the machine guess buys it
nothing in power, since any nondeterministic automaton has a deterministic
equivalent. Three things that look nothing alike - an expression you can type, a
machine you can draw, a program you can run - turned out to be the same object
wearing different clothes.

Ken Thompson made that equivalence operational in
*[Regular Expression Search Algorithm](https://doi.org/10.1145/363347.363387)*
(CACM, 1968): compile the expression into machine code, then run the input
through it, simulating all live states at once so the cost per byte stays
bounded no matter how ambiguous the pattern is. Everything gist's default engine
does descends directly from that paper. A regular expression is not a string
matcher with extra syntax; it is a program you generate, and the field's whole
performance story is about how cleverly you generate and then avoid running it.

### Shannon, and where he shows up here

Claude Shannon's 1948 *A Mathematical Theory of Communication* is the other
root, and it turns out to be load-bearing in three separate places in this
codebase.

First, it is the reason an index can work at all. A trigram filter is a bet that
source text is wildly non-uniform - that `pgx` is rare and `for` is not. If code
were uniform random bytes, every three-byte window would be equally likely,
no n-gram would prune anything, and the entire indexed-search family would be
pointless. Redundancy is what we are selling. Second, it is the unit ranking is
priced in: shape rarity erases a line's vocabulary, hashes the residue, and
prices it at `log₂(N/df)`, so a ubiquitous call-site geometry costs nothing and
a rare one keeps full credit. Third, it is the yardstick the codex self-index is
held to, since a searchable index that lands *below* the order-0 entropy of the
text it indexes is a claim you can only state in Shannon's units.

Kleene tells you what a pattern is. Shannon tells you why you get to skip most
of the corpus. The rest is engineering.

### grep was not written overnight

The story everybody tells is that Ken Thompson wrote grep in a night. It is a
great story, and the person who debunked it is Thompson.

What happened, per  
[the accounts of the people in the room](https://thenewstack.io/brian-kernighan-remembers-the-origins-of-grep/):  
Lee McMahon wanted to search the Federalist Papers for authorship clues, and  
`ed` - Thompson's own editor, which had perfectly good regular expressions -  
loaded whole files into memory to support random-access editing and therefore  
choked on a megabyte. 

Doug McIlroy, in his own telling, "asked Ken Thompson if  
he could lift the regular expression recognizer out of the editor and make a  
one-pass program to do it," and found a note the next morning announcing a  
program named grep. 

But Thompson's version is better: he already had one. A  
private tool called `s`, for search. He said he would think about McIlroy's  
request overnight, spent about an hour improving a program that already existed,  
and presented it the next day. The legend of the overnight miracle is an  
artifact of a man being modest about a head start.

The name is the `ed` command it replaced, `g/re/p` - global, regular expression,
print - and it shipped in Version 4 Unix, written in PDP-11 assembly. McIlroy
later credited grep with "irrevocably ingraining" the tools philosophy into
Unix, which is a large claim for a program whose entire design is an extraction:
take the recognizer out of the editor and point it at a stream too big to hold.
Every grep since, including this one, is that same move performed against a
corpus that has outgrown something.

### The schism: two roads out of Thompson

Thompson's linear road was not the one the field took. Henry Spencer's
widely-copied backtracking engine, and then Perl, went the other way, and for a
good reason: backtracking can express lookaround and backreferences, which are
not regular in Kleene's sense at all. The price was catastrophic blowup, where an
innocent-looking pattern goes exponential on an unlucky input.

Russ Cox put the linear road back on the map with
*[Regular Expression Matching Can Be Simple And Fast](https://swtch.com/~rsc/regexp/regexp1.html)*
and productionized it as [RE2](https://github.com/google/re2); Rust's
[regex crate](https://github.com/rust-lang/regex) carried the same guarantee
into ripgrep. 

That is the fork gist sits on deliberately: the default engine is
linear in the Thompson/Pike tradition, so a pathological pattern cannot detonate,
and the vendored [PCRE2](https://www.pcre.org/current/doc/html/) JIT is opted
into with `-P` rather than disguised as linear. 

Nobody gets to promise both without saying which one they gave you.

### Two lineages of tools, and ripgrep's merge

Gallant's taxonomy is the clearest one available, and it is his rather than  
mine. Command-line search split into two families with different obsessions.  
The grep-descended tools - GNU grep, `sift` - got very good at blowing through enormous files; they search what you point them at and treat file selection as your problem. 

The ack-descended tools - `ack`, `ag`, `ucg`, `pt` - inverted the
priority: be smart about *which* files, read your source-control configuration,
skip `node_modules` and vendored trees and binaries, and accept a slower scan for
a much smaller one. `git grep` is the interesting hybrid of manners: its flags
read like grep's while its default behavior is pure ack, since it searches only
what is checked in.

Ripgrep merged the two, and that merge is the reason it won. A genuinely fast
regex engine with literal prefiltering, riding a parallel directory traversal
that honors `.gitignore` by default. Both costs attacked at once instead of one
traded against the other.

### The third lineage: indexes

There is a third family, and the first two structurally cannot contain it,
because both of them re-read the tree on every query. If you are willing to
remember something between queries, the shape of the problem changes.

Russ Cox laid out the canonical construction in
*[Regular Expression Matching with a Trigram Index](https://swtch.com/~rsc/regexp/regexp4.html)*
(2012), the design behind Google Code Search: extract from the regex the
trigrams a match *must* contain, turn that into a boolean query over posting
lists, and verify only the survivors with a real matcher.
[google/codesearch](https://github.com/google/codesearch) ships it as
`cindex`/`csearch`, and it is gist's direct ancestor - the candidate index here
is that idea, carefully.

The family fanned out from there, and each member picked a different thing to
spend:

- [Hound](https://github.com/hound-search/hound) wraps Cox's design per
repository behind a service and a browser UI.
- [livegrep](https://blog.nelhage.com/2015/02/regular-expression-search-with-suffix-arrays/)
changed the index rather than the plan: Nelson Elhage flattens the whole
corpus into one buffer, builds a **suffix array** over it, compiles the regex
into an `IndexKey` with a selectivity estimate, binary-searches ranges, and
hands candidates to RE2. Substrings a trigram index cannot see, at the cost of
an index and a resident backend.
- [Zoekt](https://github.com/sourcegraph/zoekt) went positional - trigrams that
remember *where* - plus mmap-friendly shards, ranking, and ctags symbols; it
is the engine under Sourcegraph.
- GitHub's [Blackbird](https://github.blog/engineering/architecture-optimization/the-technology-behind-githubs-new-code-search/)
took the same presence idea to global scale with sparse variable-length
n-grams.
- [qgrep](https://github.com/zeux/qgrep) searches a compressed indexed *copy*,
and Postgres carries the whole trick inside a database as
`[pg_trgm](https://github.com/postgres/postgres/blob/master/contrib/pg_trgm/trgm_regexp.c)`,
which walks a color-trigram graph off the regex automaton.

Google's own arc is documented in
*[Software Engineering at Google*, ch. 17](https://abseil.io/resources/swe-book/html/ch17.html):
trigrams, then suffix arrays, then sparse n-grams, each step a different bet on
index size against query cost. 

The literature is equally explicit about the
limits - [Cho & Rajagopalan (2002)](https://doi.org/10.1109/ICDE.2002.994755) on
selective multi-gram indexes,
[Gibney & Thankachan (2021)](https://doi.org/10.3390/a14050133) on conditional
lower bounds for regex indexing, and
[Zhang et al. (2025)](https://www.vldb.org/pvldb/vol18/p5703-zhang.pdf) on
modern n-gram selection.

Two things are true of every member of that family, mine included. The first is
a blind spot: they all test **presence**, so a pattern with no literal in it -
`[0-9a-f]{12}`, which is what a hunt for a hash or a MAC address looks like -
proves nothing about any file and concedes the entire corpus. 

That hole is what the crest sieve exists to close, and it is the one piece of mathematics here that is ours. 

The second is an assumption: that the index is authoritative. Perfectly reasonable when you are a hosted mirror synced from a repository. Wrong, and quietly wrong, when the thing you are indexing is a working tree somebody is editing.

### What changed, and why gist exists

The engines were not the problem. The consumer changed.

Every tool above was designed for a human: a query every few minutes, typed by
somebody who will read the results with their eyes and notice if they look
stale. What I actually have is roughly ten coding agents sharing one working
tree, issuing many small searches per session, editing the tree between those
searches, and paying for every returned line in tokens. Three consequences fall
straight out, and each one is a design constraint the field's existing answers
do not carry:

1. **Freshness stops being a nicety and becomes correctness.** An indexed
  search that hands back a line which no longer exists has not been fast; it
   has lied, and an agent has no eyes to catch it with. So the accelerators here
   are allowed to decline constantly and never allowed to invent: the tree tells
   the truth, and `--no-index` is the oracle the indexed path is tested against.
2. **A set is the wrong shape for an answer.** A human scanning 200 hits finds
  the definition instantly. An agent reads them in order and burns its context
   on call sites. Hence `--rank`, and hence the insistence that ranking only
   ever reorders a verified set.
3. **Output is a budget.** Every line costs money, which makes terseness a
  feature and the docs-versus-code partition a real axis rather than a
   convenience.

So gist is the third lineage's machinery held to the first two lineages'
contract. The index and the sieve come from Cox and the papers around him; the
argv, the ignore precedence, the exit codes, and the bytes on stdout are
ripgrep's, byte for byte, measured against a live `rg` oracle rather than
asserted. 

That is the whole bet: an agent should be able to reach for the tool
it already knows, get an answer that is current rather than merely quick, and
pay less for it.

Kleene gave us the algebra, Thompson made it a program, Haertel made the program
refuse to read, and Cox made it refuse to open the file. Each generation found a
different thing not to look at. This one adds the newest refusal available: not
looking again at what has not changed.

## Deep Dives:



## Ranking and Structure

Two mechanisms carry the weight here, and neither one is a pattern: ranking decides the order answers arrive in, anatomy decides what kind of file each path is. Both come from the same complaint - grep hands you a set, and a set is the wrong shape for the two questions I ask most.

### Ranking is fusion, not a score

The lexical tiers answer which files match, unordered. Ranking orders them with weighted Reciprocal Rank Fusion (Cormack, Clarke, Büttcher, SIGIR 2009):

```
score(d) = Σᵢ  wᵢ / (k + rankᵢ(d))          k = 60
```

It consumes *ranks*, not magnitudes, which is the whole design: match count, path depth, and a 0-to-3 declaration grade share no unit and never need one, and a new signal is purely additive.

Six signals fuse - occurrence density, declaration confidence, match-line shape rarity, path depth, an authored boost, and an optional graph centrality handed in from outside. 

The authored boost carries the heaviest weight of the six, above even the definition signal, on purpose: a generated file wins lexical density *and* the definition boost, since its stubs parse as declarations, so sinking it means outweighing both. 

**Declaration confidence** reads word boundaries and geometry rather than a keyword list, so it grades a language it has never seen. 

**Shape rarity** is Shannon pricing at line scale: erase the vocabulary (query identifier → `Q`, others → `I`, strings → `S`, numbers → `N`), hash the residue, price it `log₂(N/df)`, so ubiquitous call-site geometry prices to zero while a rare shape keeps full credit.

Every signal only reorders, so none can hide a match: `--rank` is a view over the verified set, not a lossier second search. Embeddings stay out; short keyword queries are where they collapse.

### The partition is a total function

The type table answers "which language," 223 rows. Wrong grain - asking "is this prose" with `-t` means naming a dozen types and still missing an extensionless `CHANGELOG` - so kind is its own axis, and the classifier is three lines:

```zig
pub fn of(path: []const u8) Genus {
    if (spelled(path)) |g| return g;
    if (documentation(path) and !types.isKnownType(path)) return .docs;
    return .code;
}
```

Spelling decides first; a documentation location or name speaks only for what nothing else claimed. So a Markdown file in a doc directory is prose while a `conf.py` or a docs site's `.tsx` beside it stay code, and `CMakeLists.txt` is a build recipe.

That final `return .code` is load-bearing. `docs` and `data` are the recognized sets and `code` is the leftover, so an unfamiliar extension lands there and the worst a gap can do is show one line too many. An `unknown` genus excluded from `--code` would turn every gap into a silent miss instead, which is the one failure an agent cannot detect.

## Evidence

A performance claim in a README is a wish. Every number in this section is
minted by a build target, carries the machine and the corpus that produced it,
and stops existing the moment it stops being true.

The instrument is a **dominance-and-fit certificate**, built in layers A
through L, cheapest evidence first. 

Each layer either establishes measured
dominance over a named baseline or measures fit against a stated bound; none of
them claims universal or hardware optimality, because that is not a thing a
benchmark can establish. 

The statistic is the same everywhere and it is
**fail-closed**: a win requires a lower median *and* a Mann-Whitney p < 0.05,
so a favorable mean cannot buy a verdict. The roster every gate reads is
declared in one file, and a layer that mints without a row there is a hard
failure - which is how a quietly dropped section gets caught rather than
celebrated.

Provenance for everything below: 20,660 files and 204.6 MiB of real polyglot
source, ripgrep 15.2.0, hyperfine at 20 runs plus 3 warmup, seeded 10k
bootstrap, Apple M4 Max, and a second mint on an x86_64 Linux box.

### Three tiers, one verdict


| tier                   | what is switched on                              | cells | verdict                    | vs ripgrep    |
| ---------------------- | ------------------------------------------------ | ----- | -------------------------- | ------------- |
| scanner (`--no-index`) | nothing. no index, no crest sidecar, no daemon   | 24    | 24 win · 0 parity · 0 loss | 1.93× geomean |
| cold indexed           | persisted trigram index, fresh process per query | 12    | 12 win · 0 parity · 0 loss | 5.78×–8.93×   |
| warm resident          | `gist serve`, armed watcher, RAM-resident corpus | 12    | 12 win · 0 parity · 0 loss | 33.7× geomean |


Read the first row before the third, because it is the one that settles the
obvious objection. "It only wins because it has an index" is the natural thing
to suspect, and it is testable: switch the index off, delete the sidecar,
forbid the daemon, and run a fresh process against ripgrep's home turf. gist
wins 24 of 24 certified cells at p < 0.05 with nothing on. The advantage is the
walk, the read, and the scan; the index is additive on top of a scanner that
already wins, which is why turning it off costs a factor rather than the
verdict. The index then takes it a further 3.1×.

The warm geomean is the one number here I would not carry between machines,
and the second mint is why I know: 33.7× on the M4, 2.9× on the x86_64 box.
The verdict survives the move (12 win, 0 loss on both), the multiple does not.
That is what a machine-dependent figure looks like when you publish both
instead of choosing the flattering one.

### Parity is the expensive half

Speed is the cheap claim. Being *identical to ripgrep* is the hard one, and it
is measured against three denominators, two of which ripgrep owns:


| lane                   | denominator                                                                   | result                                                                   |
| ---------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| flag surface           | 186 documented flags, read at run time from rg's own completions and man page | 176 byte-identical · 10 declared boundary · **0 divergent · 0 rejected** |
| rg's integration suite | ripgrep's own `tests/` corpus, mined into replayable records                  | 411/411 of the supported surface · 0 fail · 14 declared declines         |
| differential fuzz      | 6,000 randomized pattern × flag × corpus triples over 6 adversarial corpora   | 5,967/6,000 byte-identical · **13 unresolved**                           |


The first two lanes are at 100%, and that is simultaneously their strength and
their ceiling: a curated denominator can only hold the cases somebody already
thought of. The fuzz lane generates invocations nobody wrote down, so it is the
only one still capable of finding something, and a residual of zero there would
tell me the generator had gone soft rather than that the engine had gone
correct. So the 13 are carried in the open. Two of them are ripgrep hitting the
wall where gist answered, which is not a gist failure and is not permitted to
count as one; the remaining 11 are ours, ratcheted shrink-only per class - a
class may fall, it may not rise, and a class absent from the committed baseline
fails the mint even when the total went down.

### At the floor

Layer D is not a race, it is an argument about the minimum. Verify is
Ω(candidate bytes) in the worst case - the classical Knuth-Morris-Pratt and
Boyer-Moore result, since an unread byte could be the match - and the fused
byte-class DFA reads each candidate byte **exactly once**, measured at
`passes / candidate byte = 1.0000` on every DFA class, with the SIMD literal
path strictly below 1 on vector skips and early exit. Sublinearity comes from
the other stage: the trigram prune, Russ Cox's technique and gist's direct
ancestor, which decides what verify never has to see. Two stages, one at the
information-theoretic floor and one making the input to it smaller.

### The one place the math is new

Everything above is inheritance done carefully. The **crest sieve** is not: it
is a sound necessary condition on forced class runs, which prunes exactly the
patterns every trigram-family index concedes at 100% candidates - the
literal-free class repetitions like `[0-9a-f]{12}` that a hex or UUID hunt is
made of.

Over the narrow class-repetition slate it prunes a **geomean 67% of the files
the trigram index prunes 0% of**, for a **7.5× geomean end-to-end speedup**
with the same matcher on both sides, so the win is purely avoided work. The
ablation is the part I care about: the weaker count-cousin at the same forced
bound prunes 3.3%, and that gap is what proves the *run*, not the population,
is the right condition. On the wide patterns the forced run is too short to
sieve and crest correctly prunes nothing at ~1.0×, because a manufactured win
on a row that should be flat would poison every row that isn't.

It is sound by construction rather than by testing: everything in the bound
rounds **down**, any construct the calculus cannot certify contributes nothing,
and unsafe caseless folds decline to zero - so under-pruning is the only
available failure mode. Then it is tested anyway, fail-closed, `matched ⇒ ¬pruned` against the production matcher over the corpus plus randomized
adversarial pairs in all four alphabet-by-case modes.

### Against the ancestors, and against the champion

- **csearch, on index quality** (Layer L). Not wall time, which confounds the
index with the walk and the matcher, but the honest axis: candidate bytes
admitted. One corpus, one evaluator, one verifier, varying only the boolean
formula over trigrams - and csearch's arm is csearch's own formula, lifted
verbatim from `csearch -verbose` rather than reimplemented. **6 classes won,
0 lost, 14 tied**; 1.949 GB of candidate bytes against csearch's 2.178 GB;
index 0.97× the size, built 6.4× faster. The conjunctive cover's best row cuts
candidates 83.1%.
- **Hyperscan/Vectorscan, on multi-pattern** (Layer K). The named champion for
N-expressions-one-walk with per-pattern attribution. End to end over the
corpus gist wins **2.6×** at p = 0.000183, and not by matching faster - by not
reading. Per byte, on Hyperscan's own turf, gist is ahead at every swept N
except two, where **Vectorscan takes 1.14× at N=64**. That row is printed
because a table with no losing rows is not believable.
- **ripgrep, on portability** (Layer H). 22 targets cross-compiled from one
arm64-Darwin laptop with **zero cross toolchains installed**, where ripgrep's
own matrix needs four CI runner images plus pinned containers. All 10 POSIX
triples ripgrep declares conform byte-identically on a real kernel of their
own architecture, plus 9 targets ripgrep publishes no asset for. Windows
conforms too, through Wine, and is scored on its own rung strictly below
native - a translation layer agreeing is not a kernel agreeing, and the
scorer refuses to round it up.



### Where it loses

Three places, and they are in the certificate rather than in a footnote.

**Multi-GB scale** (Layer J). Over 352,316 files and 5.5 GiB - the Linux
kernel, LLVM, Go and Rust trees - gist wins 5 classes, ties 2, and **loses 5**
to csearch. The wins are the hard end of the suite (16.5× on `})`, 9.4× on
`panic|0x`); the losses are the cheap-literal classes, where csearch answers a
rare literal in 4 ms because it does not walk a tree and is therefore not
charged for one. Peak RSS while indexing is **4.56 GiB, 2.7× zoekt's**. That is
the real ceiling in that table and it is not normalized away.

**The roofline** (Layer C). The full scan reaches 61.6 GB/s, which is 77% of
the measured 79.8 GB/s single-core pure-read roof and therefore *below* the
pre-registered 80% threshold. So Layer C certifies material headroom, not DRAM
saturation and not hardware optimality. The controls are currently slower than
the production scan they were built to bound, which means they need
re-examination before that headroom can be attributed to anything at all.

**The counters.** Cycles per byte is blank on Apple silicon, because xnu gates
the PMU to root, and LLVM ships no scheduling model for any Apple core - every
chip from the A7 to the M4 is modeled as 2013's Cyclone. So the microarchitectural
bound is computed against two cores LLVM does model precisely, Zen 4 and
Neoverse V2, and the Apple column stays empty. Blank, not estimated: a
fabricated cycle count is worse than an absent one.

```
$ bash bench/certificate/mint/mint.sh                                     # layers A-G
$ CERT_FULL=1 CERT_PUBLISH=1 CERT_SUDO=1 bash bench/certificate/mint/mint.sh   # full mint
```

The certificate is a ratchet, not a trophy case. Each layer re-derives itself on
every mint; a per-class ratio floor fails the moment a speedup drops beneath it;
and no release may claim dominance at all until the whole bundle has been
re-minted on both a Darwin and a Linux machine, because a single-machine
certificate proves gist is fast on the box that minted it and nothing further -
one M2 mint showed zero wins where the M4 sweeps the slate. The losing rows are
load-bearing. They are the reason to believe the winning ones.

Totality is enforced, not intended. The genus table derives from the type table at compile time in both directions, so a new `-t` type is a compile error until someone classifies it. That proves spellings; totality and disjointness are claims about a whole tree, so a parity gate asserts them over the live repo on every build, which is what lets `--docs` and `--no-docs` be advertised as exact complements. The taxonomy is GitHub Linguist's, minus two retrieval-driven divergences: doc directories count at any depth, and example or sample directories hold real source rather than prose.

## Divergence

Parity that is total is also a cage, so it is worth being exact about the eight
places gist does not hand back ripgrep's bytes. Every one is an **improvement**:
identical-or-superset results that are better in behavior, performance, or
robustness, never a regression. That is the only permitted category. If gist
disagrees with ripgrep anywhere outside this list, it is a bug rather than a
design choice, which is the claim the surface gate's **0 undeclared divergences**
actually measures.

The list is not prose. It is a bucket in `gist --schema`, so it can be
enumerated by a machine, and each entry declares its **reach** - how far into
your answer the difference can travel. Sorted by that, from most consequential to
least:

### Reach: corpus - files that would otherwise go unread

**`--binary` (and `-uuu`)** stops being a shrug. ripgrep finds a NUL byte, prints
`binary file matches (found "\0" byte around offset N)`, and abandons the file;
gist searches past the NUL and prints every matching line, exactly as `-a` does.
For the artifacts that actually carry a stray NUL in a source tree - minified
bundles, checked-in fixtures, mixed-content files - one opaque sentence is the
wrong answer to "where is this symbol".

**`-z` / `--search-zip`** returns ripgrep's results across every codec, verified
byte-for-byte, and gets them without a process per file: gzip, zlib, zstd, and xz
decode in-process through `std.compress`. bzip2, lz4, Brotli, lzma, and `.Z`
shell the same external tool ripgrep does. On a compressed corpus this is the
single largest edge in the tool, and it is pure plumbing.

### Reach: semantics - which patterns can be answered at all

**`-P` / `--pcre2`** is the interesting one, and as far as I can tell it does not
exist anywhere else. The vendored PCRE2 JIT returns ripgrep's exact `-P` match
set, lookaround and backreferences included, but it rides the *same* persisted
trigram prefilter the linear engine does. So a backreference query skips provably
non-candidate files rather than walking the tree. The indexed peers cannot enter
this race, because csearch and Zoekt sit on RE2-family matchers that have no
backreferences to offer; the PCRE-capable peers - ugrep, `grep -P`, git grep -
have no candidate index. Same answers, fewer bytes read. `--rank` stays
linear-only and says so.

### Reach: presentation - the same answer, better shaped

**`--type-list`** is a strict superset: ripgrep's rows byte-identical, sorted and
framed identically, plus richer definitions and gist-only types. Anything parsing
rg's format parses gist's and simply sees more.

**`--sort` / `--sortr`** produce ripgrep's exact `path`/`modified`/`accessed`/
`created` order while reading the files in parallel and ordering afterward, where
ripgrep single-threads a sorted run. `created` also falls back to ctime on
platforms with no birth time, so a sort ripgrep cannot perform still succeeds.

**`--hyperlink` / `--hyperlink-format`** defaults to `auto` rather than off, so
results are clickable when a person is reading them in a terminal that renders
OSC-8 and are plain bytes the instant they are not. The deeper difference is
architectural: in ripgrep, links are a property of the color layer - by its own
help, "hyperlinks are only written when a path is also in the output and colors
are enabled". A link into a pipe therefore costs `--color=always`, which forces
color into that pipe, and the documented escape hatch still wraps every field in
reset escapes. There is no ripgrep invocation that yields clean text plus links.
`gist --hyperlink=always` is that invocation. Nor does gist need a printed path
to have something to click; where rg drops the link when the filename is not
shown, gist anchors the line number. A link is navigation, not paint, so
`NO_COLOR` has no opinion about it, and the format grammar is rg's exactly -
a format it accepts gist accepts, one it rejects gist rejects with the same
reason - plus destination aliases rg lacks and a `link` trace lens that always
says in one line why a run linked or didn't. Two shapes refuse every posture
including `always`: `--json` records and NUL-framed `-0` lists, where the
filename's bytes *are* the payload; so does a filename carrying a control byte,
where you cannot see where the click target begins. The URL stays exact either
way - it is the text between the escapes that is withheld. Cost for 93k linked
matches is about 5 ms, roughly 60 ns each, because the URL is split once per file
into a prebuilt waypoint and a row writes only the digits.

### Reach: execution - when the bytes arrive, not what they are

Both of these keep ripgrep's promise and pay a fraction of the syscalls, on the
same run: `-n std src/`, 1.04 MB of results, identical bytes.

**`--line-buffered`** never holds a finished line, and neither does ripgrep's
`LineWriter` - but gist emits every line already in hand in one `write(2)`.
ripgrep makes 15,782 writes; gist makes 342. The flush boundary is the run's real
terminator, so `--null-data` records flush on NUL, where rg's line writer knows
only `\n` and holds NUL-delimited output until its buffer fills.

**`--block-buffered`** ramps: the first fragment leaves immediately, then the
threshold doubles toward the ceiling. `| head -1` answers instantly, a closed
pipe is discovered within a kilobyte, and a full dump settles into whole-buffer
writes - 23 writes against ripgrep's 342, or 11 at `--buffer-size=1M`, a knob
ripgrep does not have. It reaches the reader sooner as well as less often: 5 ms
to first byte against 9. This is the default posture into a pipe.

### Two things that are not divergences

`--mmap`/`--no-mmap`, `--debug`/`--trace`, and
`--dfa-size-limit`/`--regex-size-limit` are accepted compatibility no-ops - they
parse, they do nothing, and the schema says so rather than letting you believe a
knob turned. And the agent-facing output budget, roughly 25k tokens or 100 KiB
soft with a hard 256 MiB ceiling that `--uncap` lifts, is a product decision
about token cost rather than a disagreement with any rg flag.

For a versioned answer about any single flag, read `gist --schema`. A prose list
in a technical report is a snapshot; the schema is generated from the same
catalog argv is parsed with, and cannot drift from the binary that emitted it.