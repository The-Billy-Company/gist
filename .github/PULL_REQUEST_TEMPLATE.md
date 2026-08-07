<!--
Thanks for sending this. Delete any section that does not apply rather than
writing "n/a" in all of them - a short, honest PR body beats a filled-in form.
CONTRIBUTING.md has the long version of everything below.
-->

## What changed

<!-- One or two sentences in the voice of the change. What is different now? -->

## Why

<!-- The problem, not the patch. If there is an issue, link it. -->

## What proves it

<!--
The question review asks first. Name the test, the gate, the fixture, or the
oracle - and what it would have done before this change. "Existing tests pass"
is not proof that a new behaviour is right.

Touching the index, the daemon, or freshness? The check that matters is that
the accelerated answer is byte-identical to `--no-index` on a real tree.

Making a performance claim? The harness under bench/, the numbers before and
after, the machine, and the competitor versions you measured.
-->

## Parity

<!--
Does this change any flag, default, file set, output byte, or exit code
relative to ripgrep? If yes: is the divergence deliberate, and where is it
argued for? Accidental divergence is a bug here, and deliberate divergence
belongs in the README rather than only in this description.
-->

## What it costs

<!--
Allocation, syscalls, a wider public surface, a slower cold path, a new thing
someone has to install. If the answer is genuinely nothing, say so - that is
an answer.
-->

## What it replaces

<!--
If a newer path supersedes an older one, the older one should be gone in this
same PR. Two spellings of the same thing is how a codebase grows two spellings
of the same bug.
-->

---

- [ ] `zig build test` passes, and `zig fmt .` leaves the tree clean
- [ ] A news fragment is in `changelog.d/` (`+<slug>.<type>.md`), unless this is
      comment-only, format-only, or genuinely invisible
- [ ] No gate was made to skip, soften, or self-satisfy in order to go green
- [ ] A new or changed flag went into `contract/surface.toml`, so `--schema`,
      `man gist`, and every completion moved with it
- [ ] `charter.zone` is updated in this PR if a new import edge was needed
- [ ] No certificate minted over a private corpus is included
