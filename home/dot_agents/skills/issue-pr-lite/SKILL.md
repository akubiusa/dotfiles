---
name: issue-pr-lite
description: 小規模で曖昧さの少ない GitHub Issue を直接実装して PR にするための補助 skill。`$issue-pr-lite <Issue番号またはURL>`。
---

# Issue to PR: lite path

1. `gh issue view` で Issue、状態、コメント、受入条件を確認する。変更が設計判断を要するほど広がったら停止し、`$issue-pr-deep` への切替を提案する。
2. Conventional Branch を作り、Issue の要求を直接実装する。対象が dotfiles なら `home/` の chezmoi ソースを更新する。
3. 対応する検証を実行し、`$lite-review` のローカル mode で 50 以上の指摘を解消する。
4. 日本語 Conventional Commit を作成して SSH push し、`Closes #<issue>`、概要、変更内容、検証を含む PR を作成する。
5. PR 作成直後に `$pr-health-monitor <PR番号またはURL>` を実行する。

この skill は仕様/計画の承認ゲートを持たない。曖昧または高リスクな変更に対しては使わない。
