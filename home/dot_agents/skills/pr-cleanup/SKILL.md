---
name: pr-cleanup
description: merge または close 済み PR に対応するローカル worktree・ブランチを安全に片付けるときに使う。`$pr-cleanup <PR番号またはURL>`。
---

# PR Cleanup

1. URL または番号から owner/repo/PR 番号を解決する。番号だけの場合は `gh-pr-target-repo.sh --origin` を使い、fork でも local `origin` を明確にする。
2. `gh pr view <PR> --repo <owner/repo> --json state,headRefName,baseRefName,url` を実行する。state が `MERGED` または `CLOSED` 以外なら何も削除せず終了する。
3. `git worktree list --porcelain` で head branch を持つ worktree を特定する。該当 worktree は、その PR の close が確認済みの場合だけ `git worktree remove --force <path>` で削除する。通常 checkout 中の branch は削除しない。
4. `git branch -D <headRef>` は、現在 checkout 中でなく、同名 worktree もなく、PR が close 済みであることを再確認してから行う。
5. origin の default branch を `gh repo view <origin> --json defaultBranchRef` で求め、clean な checkout でのみ checkout/pull する。origin が fork のときだけ `gh repo sync <origin>` を実行する。

削除対象、実行結果、更新できなかった項目を報告する。未コミット変更や特定不能な worktree がある場合は削除せずユーザーに確認する。
