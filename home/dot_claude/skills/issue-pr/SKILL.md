---
name: issue-pr
description: Use when the user explicitly runs `/issue-pr` to turn a GitHub Issue into a pull request.
argument-hint: "[Issue number or URL]"
disable-model-invocation: true
---

# Create PR from Issue

This skill is a GitHub-specific orchestrator on top of superpowers: it chains
spec → plan → implementation → PR, with an explicit user-approval gate after
the spec and after the plan, then runs implementation and testing without
re-confirming every step. It does not reimplement spec/plan authoring,
review, or Confluence upload — those stay in superpowers.

Approval here is done via **AskUserQuestion**, not Claude Code's native Plan
Mode. Native Plan Mode only allows a single read-only-until-ExitPlanMode
gate, which cannot host writing a spec file, writing a plan file, dispatching
sub-agent review, and uploading to Confluence — all of those require
Write/Bash/MCP calls that Plan Mode blocks.

**Do not call ExitPlanMode to work around this.** ExitPlanMode exists to get
the user's sign-off on a concrete implementation plan, not to silently escape
Plan Mode. If the system-reminder shows native Plan Mode is active when this
skill starts, stop immediately and tell the user this skill needs normal
execution mode from the start (it writes files right away) — ask them to
exit Plan Mode themselves and re-run `/issue-pr`. Do not proceed past Phase 1
while Plan Mode is active. "I'll just exit once, it's harmless" is the exact
workaround this paragraph forbids — exiting Plan Mode without a real plan to
show the user is not harmless, it's the same bypass under a different name.
No exceptions.

## Prerequisites

Check before Phase 1, not after something later fails because of it:

- `gh` and `jq` must be available (`which gh jq`)
- Must be run inside a Git repository (`git rev-parse --is-inside-work-tree`)

If any prerequisite is missing, stop and tell the user what to install —
do not proceed and hit the failure several phases later.

## Progress Tracking

Before Phase 1, create one task per phase below (Phase 1 through Phase 17)
with the Todo tool, subject = the phase title. This is a long, multi-phase
flow spanning two approval gates and several delegated skills — track it
explicitly so no phase gets skipped or forgotten mid-run, especially after a
revise-and-repeat loop (Phase 5 or Phase 9) or a context compaction.

Mark each task `in_progress` immediately before starting that phase and
`completed` immediately after finishing it — do not batch updates at the
end. The task tool does not support reopening a completed task, so don't try
to; if Phase 5 or Phase 9 sends you back to an earlier phase, create new
tasks for the phases being repeated (e.g. "Phase 2: Write the Spec (revision
2)") instead.

## Phase 1: Fetch the Issue

```bash
gh issue view $ARGUMENTS --json title,state,body,comments,author
```

If this command fails (auth, network, issue doesn't exist) or the issue is
not OPEN, stop here and report it to the user — do not guess at intent and
continue. Turning a closed or nonexistent issue into a PR is not a warning-
level situation, it's a reason to stop.

## Phase 2: Write the Spec

Invoke **superpowers:brainstorming** with the issue content as the starting
problem. Relay any clarifying questions it raises to the user via
AskUserQuestion. It produces a spec file under `docs/superpowers/specs/`.

## Phase 3: Review the Spec

`rules/superpowers.md` already requires a sub-agent review of every spec
file before it is shown to the user — this fires automatically after Phase 2.
Do not reimplement it here; just wait for it to finish and confirm the
reported fixes (or resolved ambiguities) look correct before moving on.

If you don't observe the review firing (e.g. it's genuinely not configured
in this session), do not silently do the review yourself — stop and tell the
user the automatic review didn't run, and ask how they want to proceed. "It
didn't fire so I'll just do it myself" reintroduces the reimplementation this
phase exists to avoid.

## Phase 4: Upload the Spec to Confluence

`rules/confluence.md` already requires uploading spec files to Confluence
before presenting them to the user — this fires automatically once Phase 3's
review is clean. Do not reimplement the upload procedure here; just capture
the resulting Confluence URL, you need it for Phase 8 and Phase 10.

If this is a revision (you're back here after Phase 5 sent you to repeat
Phases 2–5), `rules/confluence.md` requires updating the existing spec page
via `updateConfluencePage`, not creating a new one — carry the page ID
forward from the first pass.

If Confluence/Atlassian resolution fails (no cloudId, no space configured,
MCP unavailable), follow `rules/confluence.md`'s own fallback: report the
error to the user and ask how to proceed. Don't treat Confluence as an
unconditional hard gate you can't get past.

## Phase 5: Approve the Spec

Use **AskUserQuestion** to get explicit spec approval ("Approve this spec /
revise it"). Do not proceed to Phase 6 without it. No exceptions — not for
"the spec is obviously fine," not for "the user is clearly in a hurry," not
for "I'll ask forgiveness after Phase 6 instead." If the user asks for
changes, go back to Phase 2 and repeat Phases 2–5 (Phase 4 becomes a
Confluence page update, not a new page).

## Phase 6: Write the Plan

Invoke **superpowers:writing-plans** against the approved spec to produce a
plan file under `docs/superpowers/plans/`.

## Phase 7: Review the Plan

Same as Phase 3, for the plan file: `rules/superpowers.md`'s sub-agent review
fires automatically. Wait for it and confirm the result before moving on. If
it doesn't fire, same rule as Phase 3 — stop and ask the user, don't do the
review yourself.

## Phase 8: Upload the Plan to Confluence

Same as Phase 4, for the plan file: `rules/confluence.md`'s upload fires
automatically once the review is clean. Capture the resulting Confluence URL
for Phase 10. Same revision rule as Phase 4: if this is a repeat after Phase
9 sent you back, update the existing plan page instead of creating a new
one. Same fallback as Phase 4 if Confluence resolution fails.

## Phase 9: Approve the Plan

Use **AskUserQuestion** again for explicit plan approval before moving on to
Phase 10. No exceptions — approval of the spec in Phase 5 does not carry
over to the plan; a plan can diverge from its spec, and "the spec was
already approved so the plan is implied" is exactly the shortcut this gate
exists to block. If the user asks for changes, go back to Phase 6 and repeat
Phases 6–9 (Phase 8 becomes a Confluence page update, not a new page).

## Phase 10: Comment on the Issue

Post the spec and plan summaries plus their Confluence URLs as an Issue
comment — not the full document bodies:

```bash
gh issue comment $ARGUMENTS --body "$(cat <<'EOF'
[short summary]

Spec: [Confluence URL]
Plan: [Confluence URL]
EOF
)"
```

Verify no sensitive information is included before posting.

## Phase 11: Create Branch

```bash
git fetch origin
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)
git status --porcelain   # must be empty before branching; if not, stop and ask the user
git checkout -b <branch_name> "origin/$DEFAULT_BRANCH"
```

Branch name follows Conventional Branch (feat/fix/docs/refactor), derived
from the issue number/title, e.g. `fix/123-short-description`.

If `git checkout -b` fails because `<branch_name>` already exists (e.g. a
retry after an earlier failed run), do not force-reset it with `-B` — that
discards any existing commits on it. Stop and ask the user whether to reuse,
delete, or rename.

## Phase 12: Execute the Plan

Invoke **superpowers:executing-plans** (or
**superpowers:subagent-driven-development** for independent tasks) against
the approved plan file. The plan was already approved in Phase 9 — run its
tasks without re-confirming each one with the user. Only stop for genuine
blockers the plan didn't anticipate (missing credentials, contradictory
requirements).

## Phase 13: Verify

Invoke **superpowers:verification-before-completion** before creating the PR.

## Phase 14: Deep Review

Run `/deep-review` (no arguments — local diff mode) per `rules/workflow.md`
ADR-003 and this project's Pre-PR checklist. Fix every finding scored ≥ 50
before moving on to Phase 15. This is a required gate, not an optional
extra step — skipping it is what the Stop/PostToolUse hooks exist to catch.

## Phase 15: Create PR

```bash
gh pr create --title "<title>" --body "<PR body>"
```

- `<title>`: derived from the issue title / spec summary.
- `<PR body>`: summarize from the approved spec and plan; include
  `Closes #<issue number>` so the issue auto-closes on merge.
- Language: follow the project CLAUDE.md if specified, otherwise Japanese.
  Current state only, no update history.
- Before running this command, check the composed title/body for sensitive
  information (tokens, internal URLs, credentials) the same way Phase 10
  checks the Issue comment — the PR is also externally visible.

## Phase 16: Write Session State

After PR creation, write the PR URL to the session state file so hooks can reference it
without parsing the transcript:

```bash
mkdir -p ~/.claude/data && chmod 700 ~/.claude/data
PR_URL=$(gh pr view --json url -q .url)
jq -n --arg pr_url "$PR_URL" --argjson timestamp "$(date +%s)" \
    '{"pr_url": $pr_url, "timestamp": $timestamp}' \
    > ~/.claude/data/session-state.json
chmod 600 ~/.claude/data/session-state.json
```

## Phase 17: After PR Creation

Run `/pr-health-monitor <PR number>` immediately, without asking the user
whether to run it.

Be accurate about what this actually does before relying on that to skip
confirmation: `pr-health-monitor` does not merge the PR, but it is not purely
read-only either — on CI failure it autonomously fixes and commits/pushes;
on conflicts it merges the base branch into the PR branch; it edits the PR
body; and it can trigger `/handle-pr-reviews`, which itself commits, pushes,
and resolves review threads. None of that is "merging," so the "don't merge
PRs without instruction" guardrail doesn't apply — but it is mutation of the
PR branch. The reason no separate confirmation is needed here is that Phase 9
already approved the plan and this step only carries out the mechanical
follow-through of shipping *that* approved change (fixing CI, resolving
conflicts, addressing review feedback on it) — it does not expand scope
beyond what was approved.

## Notes

- Do not drift to other tasks while waiting for review or CI.
- Record the decision log in the superpowers spec/plan files (already
  required by `rules/superpowers.md`) or in the Issue comment / PR body — not
  in extra ad-hoc Markdown files.
- `disable-model-invocation: true` is intentional: this skill ends in a
  branch and a PR, which requires explicit invocation — not opportunistic
  auto-trigger on an issue number appearing in conversation.
