---
name: wait-for-pr-close
description: GitHub PR の merge/close と conflict を監視し、close 後に `$pr-cleanup` と登録済み callback を実行するための手順。`$wait-for-pr-close <PR番号またはURL>`。
---

# PR Close Wait

Codex に session-persistent Monitor はない。`gh pr view --watch` 相当もないため、明示的に開始した短時間の polling または外部の tmux ジョブでのみ監視する。

## Callback contract

- Optional arguments are `--on-merged glitchtip-resolve --glitchtip-issue-id <ID>` only. Both arguments must be supplied together.
- `glitchtip-resolve` is a registered callback name, not a shell command. Do not accept, interpolate, or execute arbitrary callback text.
- callback mode is accepted only from the dedicated `pr_close_monitor_<OWNER>_<REPO>_<PR_NUMBER>` agent that `$pr-health-monitor` started for `$glitchtip-pr-deep` or `$glitchtip-pr-lite`. Reject callback arguments in a standalone `$wait-for-pr-close` call.
- Before `update_issue`, re-fetch `get_issue(issue_id)` and verify that the canonical PR body still contains exactly `GlitchTip Issue: <permalink URL>` using the fetched issue permalink. If the issue cannot be fetched, IDs do not match, or body metadata is absent/mismatched, skip and report the callback rejection.
- On a merged PR only, a verified `glitchtip-resolve` calls `update_issue(issue_id, status: "resolved")` once. It must never run for an unmerged `CLOSED` PR.
- This is a workflow-level provenance check, not a cryptographic binding: natural-language skills cannot authenticate a caller or persist a signed callback context. A PR editor could forge body metadata, so callback arguments must remain rejected outside the GlitchTip flow. Stronger enforcement requires a real implementation with persistent, authenticated linkage.

1. PR 番号と owner/repo を検証し、`gh pr view <PR> --repo <owner/repo> --json state,mergeable,mergeStateStatus,url` で初期状態を確認する。取得失敗時は監視を開始しない。
2. 初期 state が terminal なら、terminal action を 1 回だけ実行する。
   - `MERGED`: `$pr-cleanup <PR URL>` と、検証済みの `glitchtip-resolve` callback をそれぞれ 1 回実行する。一方が失敗しても他方は必ず試行し、cleanup failure と callback failure または rejection を別々に報告する
   - `CLOSED`: `$pr-cleanup <PR URL>` だけを 1 回実行し、その結果を報告する。callback は実行しない
3. まだ open なら、30 秒間隔で同じ `gh pr view` を poll するループをバックグラウンドで開始する(他の作業を止めない)。ユーザーからの明示的な要求がなくても、`$issue-pr-deep`/`$issue-pr-lite`/`$pr-health-monitor` からの委譲で自動的に開始してよい。5 回連続失敗したら最後のエラーを報告し、無限に黙って続けない。`CONFLICTING` への遷移は一度だけ通知する。
4. state が terminal になったら polling を止め、step 2 の terminal action を 1 回だけ実行する。

Codex セッション終了時には polling も失われる。再開時はこの skill をもう一度実行する。監視 agent の exactly-once は、その agent が terminal state を処理する 1 回と、同一 session の `$pr-health-monitor` invocation ごとの 1 task に限る。別 session の重複は検出できないため、呼び出し元は active な同一 PR 用 monitoring agent がある間に重複して開始してはならない。バックグラウンド監視のために未検証の shell 変数をコマンド文字列へ埋め込まない。
