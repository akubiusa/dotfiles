---
name: issue-pr
description: GitHub Issue を PR にするための起点 skill。Issue を取得し、規模を判断したうえで `issue-pr-deep`(仕様・計画レビューを経る本格フロー)または `issue-pr-lite`(直接実装する簡易フロー)へ引き継ぐ。明示的な `$issue-pr` 呼び出し専用。
---

# Issue から PR を作成

この skill 自身は薄いディスパッチャーであり、Issue の取得とフォーク時のベースブランチ調整、規模判断までを行い、実際の仕様策定・実装・レビュー・PR 作成は `$issue-pr-deep` または `$issue-pr-lite` に委譲する。両方とも自前で実装するのは、Claude Code 版の `issue-pr` が薄いディスパッチャーであるのと食い違うため避ける。

## 使い方

- `$issue-pr <Issue 番号または URL> [<Issue 番号または URL> ...]`
- 例:
  - `$issue-pr 123`
  - `$issue-pr https://github.com/book000/dotfiles/issues/123`

## 前提

- `gh` がインストール済みで認証済みであること
- 現在のリポジトリで作業すること
- 判断記録は Markdown ファイルではなく Issue コメントまたは PR 本文に残すこと
- PR 作成前の monitor preflight は非変更で、起動能力または選択する fallback だけを確認する。canonical PR URL を取得するまで pane の登録、state/window の作成、watcher の起動をしない。`gh pr create` の前に、PR 作成後に開始できる永続的な terminal または `$resume-pr-monitor <PR URL>` の fallback を選択して維持する。永続的な terminal または resume fallback を選択できない場合は PR を作成せず停止する。PR 作成直後に委譲先の `$pr-health-monitor` が canonical URL を取得してから state に記録する。monitor 初期化が失敗した場合の failure report には canonical PR URL、失敗した stage、fresh な evidence、正確な recovery command `$resume-pr-monitor <PR_URL>` を含め、incomplete/unmonitored と報告する。
- 複数 Issue では、すべての Issue が一意、open、target repository 所属であることを検証する。Issue ごとに確認済みの scope と acceptance criteria を残す。Issue ごとの文書、Issue ごとの review evidence、Issue ごとの closing keyword を用意する。すべての Issue の aggregate 最終ゲートが通るまで PR を作成しない。

## ワークフロー

1. 入力を解析してすべての Issue を取得する。
   - `$issue-pr` の後の各引数だけを受け付け、すべての入力を順序を保った `ISSUE_REFERENCES` 配列として解析する。空入力、`--owner`/`--repo` のような dispatcher の option、重複する number または canonical URL は error とする。重複を除外して続行してはならない。
   - `TARGET_REPOSITORY=$(gh-pr-target-repo.sh)` で PR 作成先を先に解決し、`ISSUE_OWNER` と `ISSUE_REPO` をそこから得る。各 `ISSUE_REFERENCE` を `gh issue view "$ISSUE_REFERENCE" --repo "$TARGET_REPOSITORY"` で取得する。
   - 返った number、canonical URL、state を記録し、URL が `https://github.com/$TARGET_REPOSITORY/issues/<number>` であること、すべて unique かつ `open` であることを照合する。canonical URL の順序を保った `ISSUE_IDENTITIES` 配列を作る。1 件でも存在しない、closed、別 repository、重複なら委譲も PR 作成も行わず停止する。
2. 以降のすべてのフェーズ(Issue コメント投稿、PR 作成先解決)は検証済みの `ISSUE_OWNER/ISSUE_REPO` を基準にする。ローカルの `origin` がフォークかどうかとは無関係。
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
5. 検証済みの全 Issue をまとめて規模判断し、1 件でも deep 条件なら deep path を選ぶ。判断結果に応じて全 identity を委譲する。
   - 小規模: `$issue-pr-lite "${ISSUE_IDENTITIES[@]}" --owner "$ISSUE_OWNER" --repo "$ISSUE_REPO"`
   - それ以外: `$issue-pr-deep "${ISSUE_IDENTITIES[@]}" --owner "$ISSUE_OWNER" --repo "$ISSUE_REPO"`
   - `ISSUE_OWNER`/`ISSUE_REPO` と `ISSUE_IDENTITIES` を明示的に渡す。委譲先は会話の文脈だけに依存せず、全 Issue の canonical URL、number、本文を受け取る。

この skill 自身にはこれ以降のフェーズ(仕様・実装・PR 作成)はない。すべて委譲先の責任とする。

## 注意事項

- Codex CLI の公式機能では、Claude Code のような任意の custom slash command を追加しない。コマンド相当は skill に置き換える。
- レビュー待ちや CI 待ちの間に別作業へ逸れない。PR 後フローを最後まで回す。
