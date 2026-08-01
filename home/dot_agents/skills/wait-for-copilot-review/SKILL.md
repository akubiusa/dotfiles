---
name: wait-for-copilot-review
description: GitHub Copilot の PR レビューを検出して `$handle-pr-reviews` へつなぐための監視手順。`$wait-for-copilot-review <PR番号またはURL>`。
---

# Copilot Review Wait

Codex には Claude の Monitor tool がないため、repo 配下の永続監視ではなく `pr-health-monitor` の補助スクリプトを使う。

1. PR 番号と owner/repo を検証する。番号は数字のみ、owner/repo は GitHub 名として妥当な文字だけ許可する。
2. GraphQL で既存の Copilot review を確認する。存在すればただちに `$handle-pr-reviews <PR URL>` を実行する。
3. 存在しなければ `~/.agents/skills/pr-health-monitor/scripts/wait-for-copilot-review.sh <PR番号またはURL> &` を開始する。スクリプトは 30 秒間隔で確認し、検出時に tmux の Codex セッションへ review handling を通知する。
4. tmux がない、またはセッション終了後は自動引継ぎできない。その場合は監視を開始できなかったことを報告し、後で `$handle-pr-reviews` を手動実行するよう案内する。

監視開始は既に承認された PR 後フローの一部である。レビュー依頼の可否や GitHub 権限の失敗は、PR 作成自体の失敗として扱わない。
