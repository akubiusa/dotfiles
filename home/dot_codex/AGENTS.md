## 基本方針

- ユーザーの明示的な承認なしに、フック・設定・PR を変更しない。PR は明示的な指示があるまでマージしない。
- 前提・仮定・不確実性を明示し、実装を危険にする曖昧さがある場合は質問する。外部仕様は一次情報で確認する。
- 最終回答は日本語、途中経過は簡潔な英語で記載する。コードコメントはリポジトリの指示に従い、未指定なら日本語、エラーメッセージは英語にする。日本語と英数字の間には半角スペースを入れる。
- 判断記録はローカルの Markdown ファイルではなく、GitHub Issue コメントまたは PR 本文に残す。
- 読み書きの対象が Codex 自身の指示・skill・hook・settings である場合は、影響範囲を分離するためサブエージェントに委譲する。chezmoi 管理対象は展開先ではなく `home/` 配下のソースを更新する。

## Git と PR

- ブランチは Conventional Branch の短縮形、コミットは Conventional Commits を使う。説明文の言語はリポジトリの指示に従い、未指定なら日本語にする。
- SSH で push する。`GH_CONFIG_DIR`、`GIT_*`、`GIT_SSH_COMMAND` は許可なく変更せず、Git の username/email も変更しない。Renovate が作成した PR にはコミットしない。
- 実装前に、リポジトリ構成、作業ブランチ、最新のリモート既定ブランチ、不要なローカルブランチ、必要な依存関係を確認する。調査目的の GitHub リポジトリは一時ディレクトリへ clone する。
- コミット前に、秘密情報、lint/format エラー、必要な検証、期待どおりの動作を確認する。
- PR 作成前に、ユーザーの依頼、秘密情報、競合リスク、変更内容に応じたローカルコードレビューを確認する。PR 作成先は `gh-pr-target-repo.sh` を優先し、GitHub の `upstream` remote があればそれを既定にする。
- PR 本文には現在の状態のみを記載し、更新履歴を列挙しない。PR 作成後は `$pr-health-monitor` を実行し、CI、競合、Codex/Copilot レビューを確認する。未解決レビューの対応は `$handle-pr-reviews` を使う。

## 実装と検証

- 既存の構成・命名に合わせ、コードで明らかな内容をコメントで重複させない。コメントは理由・制約・将来壊れうる前提だけに使い、変更履歴を残さない。
- リポジトリ構成・利用手順・テスト・セキュリティ方針を変える場合は、README、プロジェクトの指示、Copilot 向け指示の更新要否を確認する。
- 変更に対応する syntax、unit、integration テストを実行する。通知・フック・helper を変更または削除した場合は、テスト内の参照も確認する。
- chezmoi では `executable_` 接頭辞が展開時に除去される。設定からスクリプトを参照するときは、展開後の名前を使う。

## 追加ガイダンス

- 外部ライブラリやフレームワークの API、設定、互換性、非推奨化、バージョン差異を扱うときは、プロジェクトの lockfile 等から対象バージョンを特定し、一次情報で確認する。特定できなければ不明と明記して分岐を示す。
- ユーザーへの確認は、現在の対話環境で利用できる質問機能を使う。要件が複数に解釈できるときは、勝手に選ばない。
- Markdown の段落途中で手動改行しない。箇条書き、表、見出し、コードブロックはこの制約の対象外とする。
- GitHub Issue に紐付く仕様・計画・調査の成果物は、秘密情報を確認した上で Issue コメントへ投稿し、投稿後は URL のみを報告する。別々の文書は別コメントにし、更新時はそのコメント ID を指定する。Issue と無関係な文書の保存先は、利用可能な skill またはユーザーの指示に従う。
- `docs/superpowers/specs/` または `docs/superpowers/plans/` を作成・更新した後、ユーザーへ提示する前に `spec_reviewer` または `plan_reviewer` agent にレビューと修正を依頼する。これらのローカル成果物が ignore 対象なら force-add しない。

変更対象に応じて、以下の reference を先に読む。

| 対象 | Reference |
| --- | --- |
| 共通のコード品質、秘密情報、破壊的操作、依存関係、入力処理 | `~/.codex/references/coding-and-security.md` |
| TypeScript / JavaScript | `~/.codex/references/typescript-javascript.md` |
| Python、Shell、Dockerfile | `~/.codex/references/python-shell-docker.md` |
| C#、`.csproj`、`.sln`、`.editorconfig` | `~/.codex/references/csharp.md` |
| GitHub Actions workflow | `~/.codex/references/github-actions.md` |
| GitHub Issue 文書、Jira、agent 委譲 | `~/.codex/references/workflow.md` |

## Codex Skills

Codex CLI では任意の custom slash command ではなく、skill でコマンド相当のワークフローを提供する。Codex は repo / user / admin / system scope の skill を読み込む。この dotfiles は user scope の `~/.agents/skills` を管理する。

- この dotfiles が管理する skill は `~/.agents/skills` に配置する。
- 明示的な実行には `$` で skill を指定する。
- `$issue-pr`: GitHub Issue から実装、PR 作成、PR 後フロー開始までを行う。
- `$ticket-pr`: Jira チケットから実装、PR 作成、PR 後フロー開始までを行う。
- `$pr-health-monitor`: PR の CI、競合、本文、Codex/Copilot レビューを確認する。
- `$handle-pr-reviews`: 未解決レビュースレッドを修正、返信、resolve まで処理する。
- `$deep-review` / `$lite-review`: 変更を複数観点または重点観点でレビューする。
- `$issue-pr-deep` / `$issue-pr-lite`: 規模に応じて GitHub Issue から PR を作成する。
- `$pr-cleanup`: マージ済み PR の後処理を行う。
- `$wait-for-copilot-review` / `$wait-for-pr-close`: PR のレビューまたはクローズを監視する。
- `$check-container-status`: Docker Compose プロジェクトの状態を確認する。
- `$claude-md-maintainer`: エージェント向けガイダンスを保守する。
- `$rtk`: RTK の利用手順を参照する。
- `$trilium`: Trilium 連携の手順を実行する。
- skill を更新しても一覧へ反映されない場合は Codex を再起動する。
