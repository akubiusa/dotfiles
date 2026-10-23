---
name: wait-for-pr-close
description: Use to monitor a GitHub PR's close/merge and conflicts as durable events. `$wait-for-pr-close <PR number or URL>`.
---

# PR Close Wait

`$wait-for-pr-close <PR number or URL>` guides the foreground watcher part of `$pr-health-monitor`. The watcher polls PR state, checks, conflict, and review feedback regardless of actor and only records events in the XDG state; it does not run `$pr-cleanup`, Git operations, or a GlitchTip callback.

1. Get the canonical `PR_URL` with `gh pr view`. To resolve the repository for a bare number, prefer `gh-pr-target-repo.sh` and the GitHub `upstream` remote.
2. `start` launches a supervisor in a dedicated tmux window if a tmux pane is registered via `$pr-health-monitor`. Only if the pane is unregistered or the launch/readiness check fails, record `foreground_required` and exit. Only when the user can explicitly provide a persistent terminal, run `~/.agents/skills/pr-health-monitor/scripts/watch-pr.sh watch --pr-url "$PR_URL"` in the foreground. Otherwise, proceed to the resume fallback.
3. Merge/close, CI failure, conflict, and review feedback are stored as pending events in `${XDG_STATE_HOME:-~/.local/state}/codex-pr-monitor/`. Review feedback is sent to `$handle-pr-reviews`. The watcher stops on 5 consecutive API failures.
4. After a terminal state, insufficient agent capacity, lack of tmux support, a Codex restart, or a watcher stop, run `$resume-pr-monitor <PR_URL>`. If ChatGPT Desktop/Web Scheduled Tasks are available, the resume can be scheduled in the project context, but this is not background monitoring in a local shell. The resume first reconciles events from fresh GitHub state and processes only the actions whose lease it could acquire.

The GlitchTip callback descriptor is not stored in durable state. GlitchTip Resolve is performed only in a verified flow that the user explicitly requested, when `MERGED`, `get_issue`, the permalink, and the PR body can be re-verified. It is not performed for `CLOSED`.
