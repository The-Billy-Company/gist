- **A release page now carries the binaries it built.** Every release since
  v1.2.0 shipped an empty asset list under a README that opens by telling you to
  download one. The archives were real - built by the `build` matrix, unpacked
  and run against a live corpus by all six `smoke` jobs - and then the job whose
  only remaining work was `gh release upload` failed before reaching it, on the
  integrity check ahead of it.

  `SHA256SUMS` names its files the way the person who downloads them will: bare,
  beside the sums file. The check ran a directory up, so `shasum -c` looked for
  six archives that were one level down, called all six unreadable, and `set -e`
  ended the job with the upload still ahead of it. It is a two-line failure that
  read like a security stop, which is why it survived four releases: the log's
  own last words are `FAILED open or read`, and nothing above them says the
  bytes were fine.

  The verification now runs from inside the download directory, where the names
  in the file resolve. Verified against the v1.2.3 archives themselves: six for
  six `OK`, then attached, so that release has its downloads even though its own
  run predated this fix.
