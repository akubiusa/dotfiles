---
name: pr-cleanup
description: Use to safely clean up the local worktree and branch corresponding to a merged or closed PR. `$pr-cleanup <PR number or URL>`.
---

# PR Cleanup

1. Resolve owner/repo/PR number from the URL or number. For a bare number, use `gh-pr-target-repo.sh --origin` so that the local `origin` is clear even for a fork.
2. Run `gh pr view <PR> --repo <owner/repo> --json state,headRefName,baseRefName,url`. If the state is anything other than `MERGED` or `CLOSED`, delete nothing and exit.
3. Identify the worktree that holds the head branch with `git worktree list --porcelain`. Delete that worktree with `git worktree remove --force <path>` only if the close of that PR has been confirmed. Do not delete a branch that is in a normal checkout.
4. Run `git branch -D <headRef>` only after reconfirming that it is not currently checked out, that no worktree of the same name exists, and that the PR is closed.
5. Determine origin's default branch with `gh repo view <origin> --json defaultBranchRef`, and checkout/pull only in a clean checkout. Run `gh repo sync <origin>` only when origin is a fork.

Report the deletion targets, the results, and the items that could not be updated. If there are uncommitted changes or a worktree that cannot be identified, do not delete and ask the user.
