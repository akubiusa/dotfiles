---
name: wait-for-copilot-review
description: Use to detect a GitHub Copilot PR review as a durable event. `$wait-for-copilot-review <PR number or URL>`.
---

# Copilot Review Wait

1. Validate the canonical `PR_URL`, and start `~/.agents/skills/pr-health-monitor/scripts/wait-for-copilot-review.sh "$PR_URL" &` on a best-effort basis.
2. When the script detects a Copilot review via GraphQL, it only records a `copilot_review` event in the XDG state of the same PR and notifies. It does not start a tmux command or `$handle-pr-reviews`.
3. `$resume-pr-monitor <PR_URL>` rechecks the review with a fresh GraphQL query and then runs `$handle-pr-reviews`. The standard fallback for insufficient agent capacity, a non-CLI environment, after a restart, or after a timeout is this resume skill, and a notification alone is not treated as completion. When using ChatGPT Desktop/Web Scheduled Tasks, also schedule the resume in the project context, and do not treat it as a detached watcher in a local shell.

Starting the monitoring is part of the already approved post-PR flow. A failure of GitHub permissions or notification is not treated as a failure of the PR creation itself.
