- **The archives attach themselves now, without a human finishing the job.**
  v1.2.4 fixed the reason this had never worked - the sums file was verified from
  one directory up, so all six archives read as unreadable and `set -e` ended the
  job - and then failed anyway, one step further along, on something the first
  fix had been hiding.

  All six verified `OK` this time. Then thirty attempts over five minutes each
  reported "no release on v1.2.4 yet" about a release that had existed for half
  an hour. `gh` resolves which repository it is talking about from a git remote,
  and this job downloads one artifact and never checks the tree out, so there was
  no remote and no repository - `gh release view` was failing on its own
  configuration, not on the release. The sibling job that posts the release notes
  makes the identical call and has always worked, because it happens to check the
  repository out for a different reason.

  Two things were wrong and both are fixed. The job now names its repository
  (`GH_REPO`) rather than inferring one from a checkout it has no other use for.
  And the wait can now tell the two answers apart: a release that does not exist
  yet is worth retrying, and anything else - a bad token, an unresolvable
  repository - is a fault that will still be true in five minutes, so it fails
  immediately with what `gh` actually said. The `2>/dev/null` that turned every
  such fault into "not yet" is gone. v1.2.4's binaries were attached by hand and
  are on its release page.
