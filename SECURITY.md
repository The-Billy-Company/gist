# Security Policy

`gist` is pointed at trees it did not write. You clone a repository you have
never read and search it; an agent walks a checkout ten other agents are
editing. So the threat model here is not "someone attacks the binary" so much as
**"the corpus is the attacker"** - hostile file names, hostile bytes, a
committed config file, a poisoned index left behind by something else. Every
one of those is input.

## Reporting a vulnerability

**Do not open a public issue, pull request, or discussion.**

Use GitHub's private reporting - the **Security** tab on this repository,
"Report a vulnerability" - which opens a thread only the maintainers can read.
If that is unavailable to you, email **security@billylives.com**.

Please include:

- what you found and what it lets an attacker do;
- the smallest reproduction you can manage: the tree (a script that builds it
  beats a tarball), the exact command line, and whether an index or a resident
  session was warm;
- `gist --version`, plus `gist status --json` if the persisted artifacts are
  involved;
- your OS and architecture, and how you installed the binary.

We will acknowledge within **72 hours** and give you a triage verdict with a
severity within **7 days**. If it is real we will agree a disclosure date with
you, credit you in the changelog fragment and the release notes unless you would
rather we did not, and ship the fix before the details go public. There is no
paid bounty.

We will not pursue anyone who reports in good faith, works against their own
machines and their own data, and gives us a reasonable window to fix the thing
before publishing.

## Supported versions

Pre-1.0, and the version number says so. Fixes land on `main` and ship in the
next release; there are no maintained release branches and no backports to
earlier tags. Watch releases on this repository if you pin.

The engine underneath is [`irregex`][irregex], a separate repository with its
own policy. A memory-safety bug in the regex engines, the walk, or the index
format is theirs; either tracker reaches us, and we will move it rather than
bounce you.

## What we consider a vulnerability here

- **An accelerator that changes an answer.** The stated law is that the tree
  tells the truth: a persisted index and a resident daemon may save work, but
  they cannot invent a file set and cannot return stale content. A crafted or
  corrupt `index.gist` that produces a hit for a file which does not contain the
  pattern - or, worse, hides a file that does - breaks the promise the whole
  design rests on. Report it as security, not as a bug.
- **A config file reaching past its ceiling.** A tree's committed
  `.irregex.toml` is read from the corpus you are searching, which means a
  repository you cloned gets a vote. Its reach is capped at **corpus**: it may
  say what the repository *is* (roots, skips, extra type names) and may never
  change what *matches*, never run a command, and never read a path outside the
  tree. A charter that escapes that ceiling is a vulnerability. So is one that
  escapes the repository boundary during discovery.
- **Escaping the search root.** A symlink, a junction, a `..` in a name, or a
  Windows path spelling that walks the engine out of the roots it was given.
- **Terminal escape injection.** Paths and matched bytes are printed, and OSC-8
  hyperlinks are emitted when stdout is an interactive terminal. Content that
  can drive a terminal emulator - relocate the cursor, rewrite earlier output,
  set the title, or forge a link target that does not match its label - is in
  scope. A pipe, a redirect, `--json`, and `-0` are supposed to be plain bytes
  with none of that layer; if any of them is not, that is the report.
- **The resident session's trust boundary.** The daemon listens on a Unix
  domain socket in the artifact home and is meant for exactly one user: the one
  who could have run the binary anyway. Anything that lets a *different* local
  user drive it, read another user's results, or plant a socket the client
  connects to instead is a vulnerability. So is a client that fails *closed* in
  a way that leaks - the documented behaviour is to fail open to a cold search.
- **The installers.** `install.ps1`, `editor/install.sh`, and `shell/install.sh`
  write to PATH, plugin directories, and completion directories. Writing
  anywhere other than the places they say, or being trickable into it, is in
  scope.
- **Memory safety anywhere in this repository.** Release builds are
  `ReleaseFast`, where Zig's safety checks are off, so a bug that is a clean
  panic in your debug build may be memory corruption in the shipped binary.

## What is not a vulnerability

- **PCRE2 backtracking behind `-P`.** PCRE2 is a backtracking engine and a
  pattern with nested quantifiers can go exponential. That is the trade you opt
  into by passing the flag, and it is why the linear engines are the default.
  Superlinear behaviour on the *linear* engine is a different story, and belongs
  in [`irregex`][irregex].
- **Cost proportional to the corpus.** A big tree takes longer than a small one,
  and a pattern with no required trigram cannot be prefiltered. That is
  arithmetic.
- **The daemon obeying the user who started it.** Same-user access is the
  design, not a hole.
- **A `.gitignore` you disagree with.** Hidden and ignored precedence is
  ripgrep's, deliberately, and `-uu` overrides it. A file you expected to see
  and did not is a parity question, not a security one - and it is worth filing
  as a parity gap.

## What already tries to catch this

None of it is a guarantee, and finding something these missed is exactly the
kind of report we want:

- differential parity against a real ripgrep on every push, on Linux and macOS,
  with the oracle installed rather than skipped - a parity gate that skips has
  stopped gating;
- a native Windows lane on **both** x64 and arm64, because compiling for Windows
  proves nothing about whether `NtCreateFile` with a directory handle actually
  descends an NTFS tree, or whether the exit-code contract survives a real
  console - and because arm64's weakly ordered memory model is where the
  session's acquire/release latch is load-bearing;
- `--no-index`, which is not only a debugging flag: the un-accelerated walk is
  the oracle the indexed path is checked against, and you can run that
  comparison yourself on any tree, any time;
- a shell conformance script that makes bash, zsh, fish, PowerShell, and mandoc
  each parse the generated menus, including a check that no completion can fork
  a subprocess at tab time;
- an architecture contract ([`contract/gist.ward`](contract/gist.ward)) that
  machine-checks the import topology.

## Provenance

[`NOTICE`](NOTICE) records what is borrowed and from whom. Nothing third-party
is bundled into this binary; the certificate measures competitors by invoking
the binaries you already have installed, rather than by vendoring them.

[irregex]: https://github.com/The-Billy-Company/irregex/blob/main/SECURITY.md
