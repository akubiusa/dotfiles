# Superpowers Workflow Rules

## Spec and Plan Agent Review

After writing a spec file (`docs/superpowers/specs/*.md`) or a plan file
(`docs/superpowers/plans/*.md`), **before asking the user to review it**,
you MUST dispatch a sub-agent to review the document and apply fixes.

### Review procedure

1. Dispatch the review sub-agent with the file path to review: the
   `spec-reviewer` sub-agent (Agent tool, `subagent_type: spec-reviewer`)
   for a spec file (`docs/superpowers/specs/*.md`), or the `plan-reviewer`
   sub-agent (`subagent_type: plan-reviewer`) for a plan file
   (`docs/superpowers/plans/*.md`).
2. Wait for the sub-agent to complete.
3. If the sub-agent reports fixes, read the updated file and confirm the
   changes look correct.
4. If the sub-agent reports ambiguities, resolve them with the user via
   AskUserQuestion before proceeding.
5. Only after all issues are resolved, post or upload the document:
   - If the document is tied to a GitHub Issue (e.g. `issue-pr` execution,
     brainstorming conducted directly on a GitHub Issue), follow
     `rules/issue-comment-docs.md` and present the user with the local file
     path and the Issue comment URL.
   - Otherwise, invoke the `trilium` skill and present the user with the
     local file path and the share URL.

### Clarifying questions

**Main agent:** All clarifying questions directed at the user MUST be asked
via the AskUserQuestion tool. Do not ask questions as plain text.

**Sub-agents:** Sub-agents cannot use AskUserQuestion. If a sub-agent needs
to ask the user something, it must report the question (with options where
applicable) back to the main agent in its output. The main agent then uses
AskUserQuestion to relay it to the user.

## Local-Only Artifacts (`.gitignore` Compliance)

`docs/superpowers/` and `.superpowers/` are intentionally excluded via the
global `.gitignore` (`home/dot_config/git/ignore`). Spec and plan documents
under these paths are local-only working artifacts — after uploading them
to Trilium (per the `trilium` skill), do NOT force-add or commit them
to git (no `git add -f`, no `--force`). The durable record is the
Trilium note, not the git history.

## Sub-Skill "Stop" Instructions Return Control, Not Pause

When an orchestrating skill instructs a superpowers sub-skill (e.g. `brainstorming`, `writing-plans`) to "stop" or "stop here" after some step, that instruction means the sub-skill returns control to the orchestrating skill — it does not mean the orchestrating skill itself pauses for user input.

Unless the orchestrating skill's next phase is an explicit `AskUserQuestion`-based approval gate (e.g. `issue-pr-deep`'s Phase 6 spec approval) or a failure condition, the orchestrating skill must continue immediately into its next automatic phase once the sub-skill returns — no waiting, no "stopping here" language directed at the user.

This distinction matters because an orchestrating skill telling a sub-skill to "stop" can be misread as a cue for the orchestrating skill itself to also stop, producing an unnecessary pause where the flow was designed to continue automatically (see Issue #324 for a concrete recurrence: `issue-pr-deep`'s Phase 3→4 transition around `brainstorming`).
