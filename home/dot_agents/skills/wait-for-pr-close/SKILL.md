---
name: wait-for-pr-close
description: GitHub PR の merge/close と conflict を監視し、close 後に `$pr-cleanup` を実行するための手順。`$wait-for-pr-close <PR番号またはURL>`。
---

# PR Close Wait

Codex に session-persistent Monitor はない。`gh pr view --watch` 相当もないため、明示的に開始した短時間の polling または外部の tmux ジョブでのみ監視する。

1. PR 番号と owner/repo を検証し、`gh pr view <PR> --repo <owner/repo> --json state,mergeable,mergeStateStatus,url` で初期状態を確認する。取得失敗時は監視を開始しない。
2. 初期 state が `MERGED` / `CLOSED` なら、ただちに `$pr-cleanup <PR URL>` を実行する。
3. まだ open なら、30 秒間隔で同じ `gh pr view` を poll するループをバックグラウンドで開始する(他の作業を止めない)。ユーザーからの明示的な要求がなくても、`$issue-pr-deep`/`$issue-pr-lite`/`$pr-health-monitor` からの委譲で自動的に開始してよい。5 回連続失敗したら最後のエラーを報告し、無限に黙って続けない。`CONFLICTING` への遷移は一度だけ通知する。
4. state が `MERGED` / `CLOSED` になったら polling を止め、`$pr-cleanup <PR URL>` を実行する。

Codex セッション終了時には polling も失われる。再開時はこの skill をもう一度実行する。バックグラウンド監視のために未検証の shell 変数をコマンド文字列へ埋め込まない。
