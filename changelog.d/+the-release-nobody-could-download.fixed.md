- **A release page now carries the binaries it built.** The job that attaches
  them arrived in v1.2.2, has run exactly twice - v1.2.2 and v1.2.3 - and failed
  both times, so it has never once put an archive on a release page while the
  README it was written for opens by telling you to download one.

  The archives were real. The `build` matrix produced all six, and all six
  `smoke` jobs unpacked one and ran it against a live corpus on its own
  architecture. Then the job whose only remaining work was `gh release upload`
  failed before reaching it, on the integrity check ahead of it.

  `SHA256SUMS` names its files the way the person who downloads them will: bare,
  beside the sums file. The check ran a directory up, so `shasum -c` looked for
  six archives that were one level down, called all six unreadable, and `set -e`
  ended the job with the upload still ahead of it. It is a one-line failure that
  read like a security stop, which is how it survived its own first release: the
  log's last words are `FAILED open or read`, and nothing above them says the
  bytes were fine.

  The verification now runs from inside the download directory, where the names
  in the file resolve. Verified against v1.2.3's own archives: six for six `OK`,
  then attached by hand, so that release has its downloads even though its run
  predated this fix.
