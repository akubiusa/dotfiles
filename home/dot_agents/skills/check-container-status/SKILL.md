---
name: check-container-status
description: Use to inspect the running state of a group of Docker Compose projects in read-only mode. Only for explicit `$check-container-status` invocations.
---

# Container Status Check

`$check-container-status [target directory]`. If the target is omitted, use the current directory.

1. Enumerate Compose projects with `~/.agents/skills/check-container-status/scripts/list-compose-dirs.sh`. Report a failure as "invalid target directory" and an empty result as "no Compose projects", distinguishing the two.
2. For each project, run `docker compose ps --all`, `docker stats --no-stream`, and `docker compose logs --tail=100`, and check the restart count, healthcheck, recent errors, and published ports. If needed, perform read-only connectivity checks from the host, not inside the container.
3. If there are many, assign Codex sub-agents with at most 5 in parallel. Do not use a persistent Cron/Monitor, as it is not a standard Codex feature. So that an interrupted run can be resumed, write pending/in_progress/done and the results to `STATE.md` directly under the target.
4. Record `ok`, `expected_down`, `warning`, `error`, and `check_failed` per project. Only for warning/error, investigate primary sources as needed and give the cause, a safe fix proposal, and a confidence level.
5. When finished, report the totals and a summary of each project, and rename `STATE.md` to `STATE.md.<timestamp>.done`. Keep only the latest one past done file.

## Safety

- Do not run `docker compose up`, `down`, `restart`, `rm`, or any command that modifies things inside a container.
- Keep fix commands obtained from diagnosis as proposals only; running them requires an explicit request from the user.
- Entries already marked `in_progress` in `STATE.md` are reset to `pending` when resuming.
