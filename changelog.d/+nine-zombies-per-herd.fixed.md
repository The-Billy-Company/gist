- **Auto-spawning the resident daemon no longer leaves a zombie behind.** It
  leaked a process-table slot in proportion to how many agents were searching,
  which is the worst possible shape for the one machine ten of them share.

  `setsid` gives the daemon its own session, so it looked detached, but it does
  not change who its parent is. With a single fork the daemon was the spawning
  CLI's direct child, so the CLI owed it a `wait` it could never afford to make -
  the daemon outlives it by design - and the kernel held an entry until the CLI
  exited. That is invisible when the spawn succeeds and ugly when it does not,
  which here is the common case: ten coworker CLIs each fork a `serve`, the
  exclusive lock admits one, and the nine losers `_exit` within microseconds.
  Nine zombies, parked on nine CLIs still running their cold walk.

  There is now a second fork. The daemon is orphaned to init the instant the
  intermediate leaves, and the intermediate is a process whose entire life is
  `setsid` + `fork` + `_exit`, so waiting on *that* is microseconds and cannot
  block on the daemon's lifetime. The CLI reaps everything it created and leaves
  nothing behind. One extra fork, paid only on the rare invocation that actually
  starts a daemon.

  Verified with a ten-CLI herd on a fresh tree: one daemon, `ppid 1`, zero
  zombies, warm queries still answered.
