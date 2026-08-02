---
name: pr-health-monitor
description: PR 作成直後に、PR 本文更新、コンフリクト確認、CI 監視、Codex レビュー、Copilot レビュー依頼と待機、close 監視の開始をまとめて進めるときに使う。明示的な `$pr-health-monitor` 呼び出し専用。
---

# PR ヘルスモニター

PR 作成直後に必要な確認(コンフリクト、PR 本文更新、CI、コードレビュー、Copilot レビュー依頼と待機)と PR close 監視 agent の起動を一括で進める skill。

## 使い方

- `$pr-health-monitor <PR 番号または URL>`
- `$pr-health-monitor <PR 番号または URL> --on-merged glitchtip-resolve --glitchtip-issue-id <ID>`
- 例:
  - `$pr-health-monitor 456`
  - `$pr-health-monitor https://github.com/book000/dotfiles/pull/456`

## 目的

PR 作成後に必要な確認を漏れなく進める。

## 手順

1. PR 情報を解決する。
   - URL なら `OWNER / REPO / PR_NUMBER` を抽出する
   - 番号だけなら `gh-pr-target-repo.sh` の結果を優先して使う
   - つまり `upstream` remote があるリポジトリでは upstream PR を既定対象にする
   - `gh pr view` で取得した `url` を以降の canonical PR URL (`PR_URL`) とする
   - `--on-merged` を指定する場合は値を登録済みの `glitchtip-resolve` に限定し、`--glitchtip-issue-id <ID>` も必須にする。`--glitchtip-issue-id` 単独、未登録 callback、任意の shell command は受け付けない
   - callback は `$glitchtip-pr-deep` または `$glitchtip-pr-lite` から渡された場合だけ受け付ける。直接の `$pr-health-monitor ... --on-merged ...` 呼び出しでは callback を拒否する
   - callback を受け付ける前に、この flow で取得済みの GlitchTip issue ID と `get_issue(issue_id)` の ID が一致することを確認する。取得した permalink を使い、`gh pr view "$PR_URL" --json body,url` の body に正確な `GlitchTip Issue: <permalink URL>` があることも確認する。不一致、取得失敗、metadata 不在では callback を拒否し、close 監視は callback なしで続ける
2. PR close 監視 agent を開始する。
   - `list_agents` で、この session に同じ canonical PR URL 用の active な `pr_close_monitor_<OWNER>_<REPO>_<PR_NUMBER>` task がないことを確認する。task name には `OWNER` と `REPO` の英小文字・数字以外を `_` に置換して使う
   - active task があれば、新しい監視を起動しない。既存 agent の task 名と canonical PR URL を報告し、呼び出し元も重複した監視を開始してはならない
   - active task がなければ、Codex の `spawn_agent` を 1 回だけ呼び、同じ Codex session の dedicated task `pr_close_monitor_<OWNER>_<REPO>_<PR_NUMBER>` を開始する。agent には canonical `PR_URL`、callback なしまたは検証済みの `glitchtip-resolve` と issue ID、callback が GlitchTip workflow から渡されたことを task input の fields として渡し、`$wait-for-pr-close` workflow を実行させる

     ```text
     spawn_agent({
       task_name: "pr_close_monitor_<OWNER>_<REPO>_<PR_NUMBER>",
       message: "Run $wait-for-pr-close with canonical PR_URL, and only the validated callback fields: on_merged=glitchtip-resolve, glitchtip_issue_id=<ID>, callback_origin=glitchtip-pr. Do not wait for the parent health workflow.",
     })
     ```

     callback がない場合は `on_merged`、`glitchtip_issue_id`、`callback_origin` fields を渡さない。任意の callback text を message や command に連結しない
   - `spawn_agent` の完了を待たず、agent ID/task 名を受け取れた場合だけ `started` と報告する。起動失敗または callback 拒否は CI、レビュー、本文更新などの health check を失敗させず、canonical PR URL と理由を報告する
   - active task がない invocation では monitoring agent を正確に 1 件起動し、active task がある invocation では 0 件を追加する。session をまたぐ永続性・重複排除は保証しない
3. コンフリクトを確認する。
   - `gh pr view "$PR_NUMBER" --json mergeable,mergeStateStatus,url`
   - コンフリクトがある場合は先に解消する
4. PR 本文を最新状態に更新する。
   - 概要
   - 変更内容
   - 検証内容
   - 前提・仮定・不確実性
5. CI を監視する。
   - `gh pr checks "$PR_NUMBER" --watch`
   - 失敗時は `gh run view <RUN_ID> --log-failed` で原因を確認して修正する
6. Codex のコードレビューを実行する。
   - `codex review --base origin/master`
   - 正しさ、回帰、セキュリティ、テスト漏れを優先して指摘を処理する
7. Copilot レビューを依頼する。
   - `request-review-copilot` が存在する場合のみ
   - `request-review-copilot "https://github.com/${OWNER}/${REPO}/pull/${PR_NUMBER}"`
8. Copilot レビュー待機を開始する。
   - `~/.agents/skills/pr-health-monitor/scripts/wait-for-copilot-review.sh "$PR_NUMBER_OR_URL" &`
   - 検出時は tmux 経由で `$handle-pr-reviews ...` を Codex セッションに送る
9. 各結果をまとめる。
   - CI
   - コンフリクト
   - PR 本文
   - Codex レビュー
   - Copilot レビュー待機状態
   - PR close 監視 agent の起動結果、agent ID/task 名、または callback / 起動を拒否した理由

## 補足

- PR close 監視 agent は `gh pr checks --watch`、Codex レビュー、Copilot レビュー待機より前に開始する。以降の health check は agent を待たずに並列で進める
- agent task と自然言語 skill には session をまたぐ永続状態や caller の暗号学的な認証がない。PR body の metadata は callback の照合に使うが、PR 編集権限を持つ者による偽装までは防げない。より強い保証には、実行可能な永続 state と認証済み linkage を持つ実装が必要になる
- `codex review` が追加のリスクを指摘したら、PR 本文も同時に更新する
