---
name: issue-pr-lite
description: 小規模で曖昧さの少ない GitHub Issue を直接実装して PR にするための補助 skill。`$issue-pr-lite <Issue 番号または URL> --owner <owner> --repo <repo>`。`$issue-pr` から委譲される想定で、単独呼び出し時は自分で owner/repo を Issue の URL から抽出する。
---

# Issue to PR: lite path

1. `gh issue view` で Issue、状態、コメント、受入条件を確認する(`--owner`/`--repo` が渡されなければ URL から自分で抽出する)。変更が設計判断を要するほど広がったら停止し、`$issue-pr-deep` への切替を提案する。
2. Conventional Branch を作り、Issue の要求を直接実装する。対象が dotfiles なら `home/` の chezmoi ソースを更新する。
3. 対応する検証を実行し、`$lite-review` のローカル mode で 50 以上の指摘を解消する。
4. 日本語 Conventional Commit を作成して SSH push し、`Closes #<issue>`、概要、変更内容、検証を含む PR を、`--owner`/`--repo` で解決済みの target repository に明示して作成する。
5. PR 作成直後に `$pr-health-monitor <PR 番号または URL>` を実行する。XDG state の watcher は close、CI failure、conflict、Copilot review を durable event として記録する。session 終了後、agent capacity がない場合、または watcher 停止後は `$resume-pr-monitor <PR URL>` を実行し、再確認済みの event だけを安全に処理する。

この skill は仕様/計画の承認ゲートを持たない。曖昧または高リスクな変更に対しては使わない。
