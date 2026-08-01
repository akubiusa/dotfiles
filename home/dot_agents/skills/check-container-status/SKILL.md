---
name: check-container-status
description: Docker Compose プロジェクト群の稼働状態を読み取り専用で点検するときに使う。明示的な `$check-container-status` 呼び出し専用。
---

# コンテナ状態確認

`$check-container-status [対象ディレクトリ]`。対象を省略した場合はカレントディレクトリを使う。

1. `~/.agents/skills/check-container-status/scripts/list-compose-dirs.sh` で Compose プロジェクトを列挙する。失敗は「対象ディレクトリが不正」、空結果は「Compose プロジェクトなし」と区別して報告する。
2. 各プロジェクトで `docker compose ps --all`、`docker stats --no-stream`、`docker compose logs --tail=100` を実行し、再起動回数、healthcheck、直近エラー、公開ポートを確認する。必要ならコンテナ内ではなくホストから read-only な疎通確認を行う。
3. 多数ある場合は Codex の sub-agent を最大 5 並列で割り当てる。永続 Cron/Monitor は Codex の標準機能ではないため使わない。中断した実行を再開できるよう、対象直下の `STATE.md` に pending/in_progress/done と結果を書く。
4. `ok`、`expected_down`、`warning`、`error`、`check_failed` をプロジェクトごとに記録する。warning/error だけは必要に応じて一次情報を調査し、原因・安全な修正案・確信度を示す。
5. 完了後、集計と各プロジェクトの要約を報告し、`STATE.md` を `STATE.md.<timestamp>.done` にリネームする。過去の done ファイルは最新 1 件だけ残す。

## 安全性

- `docker compose up`、`down`、`restart`、`rm`、コンテナ内の変更コマンドは実行しない。
- 診断で得た修正コマンドは提案に留め、実行にはユーザーの明示的な依頼を要する。
- `STATE.md` の既存 `in_progress` は再開時に `pending` へ戻す。
