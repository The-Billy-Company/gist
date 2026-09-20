- **A query that finds the index has stopped paying re-anchors it in the
  background.** The engine has always been able to tell: `stale > elided` is
  arithmetic on the reads this run elided against the ones it bought back, and
  it printed a very good note saying so. A note is an instruction to whoever is
  reading, and increasingly nobody is - an agent gets stderr as one line of a
  receipt, and a user running the bundled binary has no terminal at all. An
  index nobody re-anchors does not sit still. It ages past the point where it
  saves anything and keeps charging for the bookkeeping, which is what "it got
  slow for no reason" actually is.

  So the query that notices starts the repair and does not wait for it: the
  amend runs detached and this query answers cold, exactly like the daemon
  auto-spawn beside it and for the same reason - the run in hand is already
  correct and must not get slower to make the next one faster. The amend is
  milliseconds when the annals or the journal can name the changed set.

  Nothing here is a timer. The spawned build takes the new per-tree build lock,
  so however many queries notice at once exactly one build happens; and a
  successful amend advances the anchor, which retires the condition - the reflex
  stops firing because the thing it fires on stopped being true.
  `GIST_NO_REANCHOR` declines it.

- **`gist index` is a singleton per tree.** A full build reads the whole corpus,
  and ten coworker agents reaching the verb at once simply ran it ten times over
  the same files. The daemon has admitted exactly one racer since it existed;
  the build now takes the same advisory lock, beside the artifacts it guards.
  Losers say a build is already running and exit 0 - a maintenance action
  somebody else is performing has been performed.
