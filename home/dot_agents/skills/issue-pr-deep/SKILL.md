---
name: issue-pr-deep
description: 非自明な GitHub Issue を仕様・計画・実装・深いレビューを経て PR にするための補助 skill。`$issue-pr-deep <Issue番号またはURL>`。
---

# Issue to PR: deep path

1. Issue と対象リポジトリを `gh issue view` で取得し、closed なら停止する。要件の曖昧さ、影響範囲、受入条件を整理する。
2. 仕様を Markdown で作成し、Issue にコメントとして投稿する。実装方針に重大な選択肢があるときだけ、投稿 URL を添えてユーザーへ承認を求める。修正要求なら同じコメントを更新する。
3. 承認済み仕様から実装計画を作成し、Issue へ別コメントとして投稿する。仕様・計画に秘密情報を含めない。
4. Conventional Branch を作成し、計画を実装する。各変更を検証し、失敗や未解決の不確実性があれば PR 作成前に停止する。
5. `$deep-review` をローカル差分に実行し、50 以上の指摘を解消する。確認後に日本語 Conventional Commit でコミットし SSH push する。
6. `Closes #<issue>`、概要、変更内容、検証、前提を含む PR を、解決済みの target repository に明示して作成する。続けて `$pr-health-monitor` を実行する。

Claude 専用の superpowers、EnterWorktree、AskUserQuestion は使用しない。Codex の plan、sub-agent、通常のユーザー質問に置き換える。
