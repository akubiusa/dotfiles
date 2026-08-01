---
id: c
name: history-context
title: History and PR Context
applies_to: all
---

## Scope

Check `git blame` and `git log` for changed files. Report issues only when historical context reveals a problem that is not visible from the diff alone — reverted fixes, compatibility constraints, or intent that the new change contradicts. Do not report speculation without a concrete historical reference.

PR mode only: also find recently merged PRs that touched the same files (`gh pr list --state merged`) and check their review comments for concerns that may also apply here. In local diff mode, skip this part — there is no PR to compare against.
