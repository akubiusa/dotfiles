---
name: issue-pr
description: Entry-point skill for turning a GitHub Issue into a PR. Fetches the Issue, judges its scale, and hands off to `issue-pr-deep` (the full flow with spec and plan review) or `issue-pr-lite` (the simplified flow that implements directly). For explicit `$issue-pr` invocations only.
---

# Create a PR from an Issue

This skill itself is a thin dispatcher: it only fetches the Issue, adjusts the base branch for fork scenarios, and judges the scale, then delegates the actual spec writing, implementation, review, and PR creation to `$issue-pr-deep` or `$issue-pr-lite`. Implementing both paths itself is avoided because it would diverge from the Claude Code `issue-pr`, which is a thin dispatcher.

## Usage

- `$issue-pr <Issue number or URL> [<Issue number or URL> ...]`
- Examples:
  - `$issue-pr 123`
  - `$issue-pr https://github.com/book000/dotfiles/issues/123`

## Prerequisites

- `gh` is installed and authenticated
- Work in the current repository
- Leave decision records in Issue comments or the PR body, not in Markdown files
- The monitor preflight before PR creation is non-mutating and only checks the launch capability or the fallback to select. Do not register a pane, create state or a window, or start the watcher until the canonical PR URL is obtained. Before `gh pr create`, select and keep a persistent terminal that can be started after PR creation, or the fallback of `$resume-pr-monitor <PR URL>`. If neither a persistent terminal nor the resume fallback can be selected, do not create the PR and stop. Immediately after PR creation, the delegated `$pr-health-monitor` obtains the canonical URL and then records it in state. If monitor initialization fails, the failure report must include the canonical PR URL, the failed stage, fresh evidence, and the exact recovery command `$resume-pr-monitor <PR_URL>`, and must report the PR as incomplete/unmonitored.
- For multiple Issues, verify that every Issue is unique, open, and belongs to the target repository. Keep the confirmed scope and acceptance criteria for each Issue. Prepare documents per Issue, review evidence per Issue, and a closing keyword per Issue. Do not create the PR until the aggregate final gate for all Issues has passed.

## Workflow

1. Parse the input and fetch all Issues.
   - Accept only the arguments after `$issue-pr`, and parse all inputs into an order-preserving `ISSUE_REFERENCES` array. Treat empty input, dispatcher options such as `--owner`/`--repo`, and duplicate numbers or canonical URLs as errors. Do not deduplicate and continue.
   - Resolve the PR target first with `TARGET_REPOSITORY=$(gh-pr-target-repo.sh)`, and derive `ISSUE_OWNER` and `ISSUE_REPO` from it. Fetch each `ISSUE_REFERENCE` with `gh issue view "$ISSUE_REFERENCE" --repo "$TARGET_REPOSITORY"`.
   - Record the returned number, canonical URL, and state, and verify that each URL is `https://github.com/$TARGET_REPOSITORY/issues/<number>` and that all are unique and `open`. Build an order-preserving `ISSUE_IDENTITIES` array of canonical URLs. If even one Issue does not exist, is closed, belongs to another repository, or is a duplicate, stop without delegating or creating a PR.
2. All subsequent phases (posting Issue comments, resolving the PR target) are based on the verified `ISSUE_OWNER/ISSUE_REPO`, regardless of whether the local `origin` is a fork.
3. Adjust the base branch for the fork scenario.
   - Resolve the owner/repo of `origin` itself with `ORIGIN_REPO_FULL=$(gh-pr-target-repo.sh --origin)`
     - Do not call `gh repo view` without `--origin`: when both `origin` and `upstream` exist it may resolve ambiguously to `upstream` and misjudge the fork
   - If `$ISSUE_OWNER/$ISSUE_REPO` differs from the owner/repo of `origin` (a fork handling an upstream Issue), fetch the default branch from a remote that points at `$ISSUE_OWNER/$ISSUE_REPO` (reuse an existing one, or add one named `upstream` if none exists) and use it as the base of the branch to be created
4. Judge the scale (do not ask the user; decide yourself).
   - Judge it "small-scale" only if all of the following hold:
     - The change is confined to a single file or very few files
     - It requires no design decisions such as choosing an architecture or implementation approach (typical examples: typo fixes, config value changes, wording fixes, small additions following an existing pattern)
     - There is no ambiguity in interpreting the Issue body
   - When in doubt, always choose the safe side (`issue-pr-deep`)
   - Add a one-line reason for the choice and proceed directly to the next phase without asking questions
5. Judge the scale of all verified Issues together, and choose the deep path if even one Issue meets the deep conditions. Delegate all identities according to the result.
   - Small-scale: `$issue-pr-lite "${ISSUE_IDENTITIES[@]}" --owner "$ISSUE_OWNER" --repo "$ISSUE_REPO"`
   - Otherwise: `$issue-pr-deep "${ISSUE_IDENTITIES[@]}" --owner "$ISSUE_OWNER" --repo "$ISSUE_REPO"`
   - Pass `ISSUE_OWNER`/`ISSUE_REPO` and `ISSUE_IDENTITIES` explicitly. The delegate receives the canonical URL, number, and body of every Issue instead of relying only on the conversation context.

This skill itself has no later phases (spec, implementation, PR creation). All of them are the delegate's responsibility.

## Notes

- Codex CLI's official features do not add arbitrary custom slash commands like Claude Code. Command equivalents are replaced by skills.
- Do not drift to other work while waiting for review or CI. Run the post-PR flow to the end.
