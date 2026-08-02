---
name: pr-health-monitor
description: PR 作成直後に本文、CI、競合、レビューを確認し、再開可能な PR 監視を開始するときに使う。明示的な `$pr-health-monitor` 呼び出し専用。
---

# PR ヘルスモニター

`$pr-health-monitor <PR 番号または URL>` は PR 作成後の確認を進め、XDG state に event を記録する観測だけを行う。watcher は観測専用で、cleanup、Git 変更、callback を実行しない。後処理は `$resume-pr-monitor` だけが行う。

## 使い方

- `$pr-health-monitor <PR 番号または URL>`

## 手順

1. PR を解決する。
   - 番号だけなら `gh-pr-target-repo.sh`、次に GitHub の `upstream` remote を優先する。
   - `gh pr view` で取得した `url` を canonical `PR_URL` とし、state/watcher にはこの URL だけを渡す。
2. detached watcher は開始しない。`start` は `foreground_required` を state に記録して終了するため、成功した background 監視として報告しない。持続した terminal を user が明示的に用意できる場合だけ、次を foreground で実行する。

   ```bash
   ~/.agents/skills/pr-health-monitor/scripts/watch-pr.sh watch --pr-url "$PR_URL"
   ```

   state は `${XDG_STATE_HOME:-~/.local/state}/codex-pr-monitor/` に最小限の PR metadata と pending/acknowledged event だけを保存し、atomic lock で重複 watcher を防ぐ。GlitchTip callback descriptor は state に保存しない。foreground terminal を使えない場合は health check を止めず、`$resume-pr-monitor <PR_URL>` を実行する。ChatGPT Desktop/Web の Scheduled Tasks を使う場合も project context の resume を予定し、local shell を detached 実行するものとして扱わない。
3. PR 本文を current status に更新する。更新前に `gh pr view "$PR_URL" --json body` で現行本文を取得し、既存の必要な link（特に `GlitchTip Issue: <permalink URL>`）を保持する。本文には概要、変更内容、実行済み検証、現在の CI/レビュー状態、前提・未解決事項だけを記載し、更新履歴は列挙しない。
4. `gh pr view "$PR_URL" --json mergeable,mergeStateStatus` と `gh pr checks "$PR_URL" --watch` で初期の競合と CI を確認する。失敗時は `gh run view <RUN_ID> --log-failed` で原因を調べる。watcher も CI failure/conflict を durable event として記録する。
5. Codex のローカルレビューを実行する。
   - `gh pr view "$PR_URL" --json headRefName,baseRefName` で head/base を取得する。
   - 現在の worktree が対象 PR の repository と head に対応することを `git remote -v` と branch で確認する。対応しない worktree で修正や `codex review` を推測実行しない。
   - 対応する場合だけ target remote の base ref を確認し、必要なら `git fetch <target-remote> <base-ref>` を実行して `codex review --base <target-remote>/<base-ref>` を使う。`origin/master` を固定値にしない。
   - 対応する checkout がない場合は、その事実を報告し、対象 repository を明示して clone/worktree を用意してから再実行する。PR の diff と review threads の確認は続けられるが、ローカル修正は行わない。
6. `request-review-copilot` が利用できる場合だけ review を依頼する。続けて `wait-for-copilot-review.sh "$PR_URL" &` を best effort で開始する。この補助 script は durable Copilot event を記録・通知するだけで、action は `$resume-pr-monitor` が実行する。
7. CI、競合、本文、ローカルレビュー、Copilot request、foreground watcher の状態または resume fallback を報告する。Codex の agent capacity がない場合、CLI 以外の場合、tmux がない場合、または session/restart 後は `$resume-pr-monitor <PR_URL>` で pending event を安全に処理する。

## 境界

- watcher は 30 秒間隔（`PR_MONITOR_INTERVAL` でテスト時のみ変更可能）で PR state、checks、Copilot review を poll し、連続 5 回の API failure で停止する。
- `MERGED`/`CLOSED`、CI failure、conflict、Copilot review は transition ごとに一度だけ記録する。action processor は event lease を取得し、成功後にだけ acknowledge するため、session をまたいでも未処理状態を失わない。
- local state は GlitchTip callback authority を持たない。GlitchTip Resolve は user が明示的に要求した verified flow でのみ、issue、permalink、PR body を再照合して実行する。
