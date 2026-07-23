---
name: check-container-status
description: Enumerates Docker Compose projects under a target directory (default current directory), comprehensively checks each one's status (running state, resource usage, restart count, logs, connectivity) via parallel sub-agents (max 5 concurrent), and reports errors with researched fixes once all directories are done. Use on a machine hosting many Docker Compose projects, e.g. /mnt/hdd/<machine-name>.
argument-hint: "[target directory]"
disable-model-invocation: true
---

# Check Container Status

Comprehensively check the running status of a directory hosting many Docker
Compose projects (e.g. `/mnt/hdd/<machine-name>`) using parallel sub-agents.

## Usage

```
/check-container-status [target directory]
```

If the argument is omitted, the current directory is the target.

## Phase A: Enumerate target directories

```bash
TARGET_DIR="${1:-$(pwd)}"
mapfile -t COMPOSE_DIRS < <(bash ~/.claude/skills/check-container-status/scripts/list-compose-dirs.sh "$TARGET_DIR")
```

If `COMPOSE_DIRS` is empty, report that no Compose project was found and
exit.

## Phase B: Initialize STATE.md / determine whether to resume

Let `STATE_FILE="$TARGET_DIR/STATE.md"`.

- If `STATE_FILE` exists and `## Queue` still has `pending` or `in_progress`
  entries remaining, treat this as resume mode. Move all `in_progress`
  entries back to `pending` before resuming processing (the previous session
  may have ended partway through, so err on the safe side).
- If `STATE_FILE` doesn't exist, or all entries are `done`, recreate it as a
  fresh run using the following format.

```markdown
# Docker Container Status Check - STATE

## Run Info
- started_at: <ISO8601>
- target_dir: <TARGET_DIR>
- cron_job_id: (appended in Phase C)

## Queue
- pending: <enumerate COMPOSE_DIRS, one per line>
- in_progress:
- done:

## Results
```

## Phase C: Orchestration loop

1. Register a 15-minute check-in job with `CronCreate`.

   ```
   CronCreate({
     cron: "*/15 * * * *",
     recurring: true,
     prompt: "check-container-status check-in: check <STATE_FILE>, move back
       to pending and restart any in_progress directory whose started_at is
       more than 30 minutes ago with no response, and if pending entries
       remain, launch the next directory into an open parallel slot. If all
       entries are done, delete this cron job via CronDelete(id=<this
       job's id>) and then proceed to Phase D."
   })
   ```

   Record the returned job ID in `STATE_FILE`'s `cron_job_id`.
   `CronCreate` is only valid within this session and disappears when the
   session ends (it also auto-expires after 7 days). If the session ends,
   the user can resume from `STATE_FILE` by invoking
   `/check-container-status` again.

2. Choose up to 5 entries from `pending` (minus however many are already
   `in_progress`), and for each of them launch the `Agent` tool with
   `run_in_background: true`.

   ```
   Agent({
     subagent_type: "container-status-checker",
     description: "Check <dir>",
     prompt: "TARGET_DIR=<dir> STATE_FILE=<STATE_FILE> PREVIOUS_CHECKED_AT=<previous checked_at, if any>",
     run_in_background: true,
   })
   ```

   Once launched, remove that directory from `STATE_FILE`'s `pending` and
   add it to `in_progress` in the form
   `<dir> (agent_id: <id>, started_at: <ISO8601>)`.

3. Every time a sub-agent reports completion, remove the corresponding
   directory from `STATE_FILE`'s `in_progress` and add it to `done`, and if
   `pending` entries remain, launch the next one the same way as Step 2
   (always keep a parallelism of 5).

4. When the 15-minute Cron check-in fires, move back to `pending` any
   `in_progress` entry whose `started_at` is more than 30 minutes ago with
   no response, and restart it the same way as Step 2.

5. Once both `pending` and `in_progress` are empty (all entries `done`), end
   the loop and delete the check-in job with
   `CronDelete({ id: <cron_job_id> })`.

## Phase D: Error investigation (bulk, after completion)

Check `STATE_FILE`'s `## Results`, and for every entry with
`status: error` or `status: warning`, launch the
`container-error-investigator` sub-agent.

```
Agent({
  subagent_type: "container-error-investigator",
  description: "Investigate <dir>",
  prompt: "TARGET_DIR=<dir> STATE_FILE=<STATE_FILE>",
})
```

`ok`/`expected_down` entries are not included in the investigation.

## Phase E: Final report

Present the following as chat output.

- Overall summary (number of target directories, breakdown of
  `ok`/`expected_down`/`warning`/`error`)
- Per-directory status list (one line of `summary` each)
- For `warning`/`error` entries, the `diagnosis` (cause, fix, confidence
  level) obtained in Phase D

After reporting, rename `STATE_FILE` to `STATE.md.<run timestamp>.done`.

```bash
mv "$STATE_FILE" "$STATE_FILE.$(date +%Y%m%d%H%M%S).done"
```

If multiple `.done` files already exist in the same directory, delete all
but the newest, keeping only the most recent generation.

## Notes

- Never run destructive commands (`docker compose restart`/`down`/`up`,
  etc.) from either this skill or its sub-agents. Stick strictly to
  read-only inspection and proposals.
- Temporary directories such as `/mnt/hdd/work/*` are not included
  automatically. If needed, specify that directory explicitly as the target
  directory argument.
- The parent session (the session running this skill) acts strictly as an
  orchestrator; running `docker compose`, analyzing logs, checking
  connectivity, and researching online are all delegated to sub-agents.
