---
name: wait-for-copilot-review
description: GitHub Copilot の PR レビューを durable event として検出するときに使う。`$wait-for-copilot-review <PR番号またはURL>`。
---

# Copilot Review Wait

1. canonical `PR_URL` を検証し、`~/.agents/skills/pr-health-monitor/scripts/wait-for-copilot-review.sh "$PR_URL" &` を best effort で開始する。
2. script は GraphQL で Copilot review を検出すると、同じ PR の XDG state に `copilot_review` event を記録して通知するだけである。tmux command や `$handle-pr-reviews` の起動は行わない。
3. `$resume-pr-monitor <PR_URL>` は fresh GraphQL query で review を再確認してから `$handle-pr-reviews` を実行する。agent capacity 不足、CLI 以外、restart 後、timeout 後の標準 fallback はこの resume skill であり、通知だけを完了扱いにしない。ChatGPT Desktop/Web の Scheduled Tasks を使う場合も project context の resume を予定し、local shell の detached watcher として扱わない。

監視開始は既に承認された PR 後フローの一部である。GitHub 権限や通知の失敗は PR 作成自体の失敗として扱わない。
