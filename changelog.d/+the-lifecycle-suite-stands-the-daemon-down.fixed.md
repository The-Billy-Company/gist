The Go index lifecycle suite gave each corpus a private artifact home, which is only half of the isolation: a resident session left over from another tree is still reachable, and this suite is about what a lifecycle verb writes to disk in *its* home, not about warm dispatch. It now stands the daemon down for the duration.

That did not account for the whole flake. The residue was an intermittent `gist status: exited -1`, which the improved child-tier diagnostic in irregex has since named a **segmentation fault** in `readGenerationFile` under `status` — a real pre-existing crash, tracked separately, not the noise it was taken for.

Module floor lowered to `go 1.24` alongside irregex.
