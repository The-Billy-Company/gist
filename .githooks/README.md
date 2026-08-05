# Git hooks

`pre-push` runs Markdown discipline against the committed bytes being pushed,
not the working tree. Enable the checked-in hooks for this clone:

```sh
git config core.hooksPath .githooks
```
