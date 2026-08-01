---
name: issue-pr
description: GitHub Issue を PR にするための起点 skill。Issue を取得し、規模を判断したうえで `issue-pr-deep`(仕様・計画レビューを経る本格フロー)または `issue-pr-lite`(直接実装する簡易フロー)へ引き継ぐ。明示的な `$issue-pr` 呼び出し専用。
---

# Issue から PR を作成

この skill 自身は薄いディスパッチャーであり、Issue の取得とフォーク時のベースブランチ調整、規模判断までを行い、実際の仕様策定・実装・レビュー・PR 作成は `$issue-pr-deep` または `$issue-pr-lite` に委譲する。両方とも自前で実装するのは、Claude Code 版の `issue-pr` が薄いディスパッチャーであるのと食い違うため避ける。

## 使い方

- `$issue-pr <Issue 番号または URL>`
- 例:
  - `$issue-pr 123`
  - `$issue-pr https://github.com/book000/dotfiles/issues/123`

## 前提

- `gh` がインストール済みで認証済みであること
- 現在のリポジトリで作業すること
- 判断記録は Markdown ファイルではなく Issue コメントまたは PR 本文に残すこと

## ワークフロー

1. Issue を取得する。
   - `gh issue view "$ARGUMENTS" --json number,title,body,state,comments,author,url`
   - closed または存在しない Issue には着手せず、ここで停止してユーザーへ報告する
2. `ISSUE_OWNER` / `ISSUE_REPO` を Issue の URL から抽出する。
   - `ISSUE_URL=$(gh issue view "$ARGUMENTS" --json url -q .url)`
   - `ISSUE_OWNER=$(echo "$ISSUE_URL" | sed -E 's#.*github\.com/([^/]+)/.*#\1#')`
   - `ISSUE_REPO=$(echo "$ISSUE_URL" | sed -E 's#.*github\.com/[^/]+/([^/]+)/issues/.*#\1#')`
   - 以降のすべてのフェーズ(Issue コメント投稿、PR 作成先解決)はこの `ISSUE_OWNER/ISSUE_REPO` を基準にする。ローカルの `origin` がフォークかどうかとは無関係。
3. フォークシナリオのベースブランチを調整する。
   - `ORIGIN_REPO_FULL=$(gh-pr-target-repo.sh --origin)` で `origin` 自体の owner/repo を解決する
     - `--origin` を付けずに `gh repo view` を呼ぶと、`origin`/`upstream` 双方が存在する場合に `upstream` 側へ曖昧に解決されることがあり、フォーク判定を誤るため使わない
   - `$ISSUE_OWNER/$ISSUE_REPO` が `origin` の owner/repo と異なる場合(フォークで upstream の Issue を扱う場合)は、`$ISSUE_OWNER/$ISSUE_REPO` を指す remote(既存のものがあれば再利用、なければ `upstream` という名前で追加)から default branch を fetch し、これから作成するブランチのベースとして使う
4. 規模を判断する(ユーザーに確認しない。自分で判断する)。
   - 次のすべてを満たす場合のみ「小規模」と判断する:
     - 変更が単一ファイルまたはごく少数のファイルに閉じている
     - アーキテクチャや実装方式の選択のような設計判断を要さない(typo 修正、設定値変更、文言修正、既存パターンに沿った小さな追加が典型例)
     - Issue 本文の解釈に曖昧さがない
   - 判断に迷う場合は必ず安全側(`issue-pr-deep`)を選ぶ
   - 選んだ理由を一言添えたうえで、質問はせずにそのまま次のフェーズへ進む
5. 判断結果に応じて委譲する。
   - 小規模: `$issue-pr-lite <Issue 番号> --owner "$ISSUE_OWNER" --repo "$ISSUE_REPO"`
   - それ以外: `$issue-pr-deep <Issue 番号> --owner "$ISSUE_OWNER" --repo "$ISSUE_REPO"`
   - `ISSUE_OWNER`/`ISSUE_REPO` は明示的に渡す。Issue 本文・Issue 番号もこの会話の文脈に残っているものをそのまま使わせる。

この skill 自身にはこれ以降のフェーズ(仕様・実装・PR 作成)はない。すべて委譲先の責任とする。

## 注意事項

- Codex CLI の公式機能では、Claude Code のような任意の custom slash command を追加しない。コマンド相当は skill に置き換える。
- レビュー待ちや CI 待ちの間に別作業へ逸れない。PR 後フローを最後まで回す。
