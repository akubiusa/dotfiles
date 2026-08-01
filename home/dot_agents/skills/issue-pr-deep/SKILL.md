---
name: issue-pr-deep
description: 非自明な GitHub Issue を仕様・計画・実装・深いレビューを経て PR にするための補助 skill。`$issue-pr-deep <Issue 番号または URL> --owner <owner> --repo <repo>`。`$issue-pr` から委譲される想定で、単独呼び出し時は自分で owner/repo を Issue の URL から抽出する。
---

# Issue to PR: deep path

1. Issue と対象リポジトリ(`--owner`/`--repo` が渡されなければ `gh issue view` の URL から自分で抽出する)を取得し、closed なら停止する。要件の曖昧さ、影響範囲、受入条件を整理する。
2. 仕様を Markdown で作成し、Issue にコメントとして投稿する。実装方針に重大な選択肢があるときだけ、投稿 URL を添えて `request_user_input` でユーザーへ承認を求める(選択肢は「承認する」「修正してほしい」の 2 択を基本にする)。修正要求なら同じコメントを更新し、新規コメントを追加しない。
3. 承認済み仕様から実装計画を作成し、Issue へ別コメントとして投稿する。仕様・計画に秘密情報を含めない。
4. Conventional Branch を作成し、計画を実装する。各変更を検証し、失敗や未解決の不確実性があれば PR 作成前に停止する。
5. `$deep-review` をローカル差分に実行し、50 以上の指摘を解消する。確認後に日本語 Conventional Commit でコミットし SSH push する。
6. `Closes #<issue>`、概要、変更内容、検証、前提を含む PR を、`--owner`/`--repo` で解決済みの target repository に明示して作成する。
7. 続けて `$pr-health-monitor` を実行する。さらに `$wait-for-pr-close <PR 番号または URL>` を実行し、PR の close をバックグラウンドで監視して close 検出時に `$pr-cleanup` へ繋ぐ。Codex にはセッションを跨ぐ永続監視がないため、これは現在のセッションが生きている間の best-effort であり、セッション終了後は手動で `$wait-for-pr-close`/`$pr-cleanup` を呼び直す必要がある。

Claude 専用の superpowers、EnterWorktree、AskUserQuestion は使用しない。Codex の plan、sub-agent、`request_user_input` ツールに置き換える。仕様・計画レビューは `home/dot_codex/AGENTS.md` の追加ガイダンスに従い `spec_reviewer`/`plan_reviewer` agent を使う。
