---
name: trilium
description: GitHub Issue に紐付かないローカル Markdown を self-hosted Trilium に ETAPI 経由でアップロードするときに使う。
---

# Trilium 文書アップロード

1. Issue に紐付く文書には使用しない。その場合は Issue コメントへ投稿する。
2. `noteId` は `[a-zA-Z0-9_]{4,32}`、`topic` は `[a-zA-Z0-9_-]{1,25}`、`docType` は `spec` / `plan` / `investigation` に検証する。
3. アップロード前に `bash ~/bin/trilium-search.sh <topic>` を実行し、既存文書があれば改訂か新規かをユーザーに確認する。
4. API token、パスワード、内部 URL、認証情報を含まないことを確認する。
5. `bash ~/bin/trilium-upload.sh <file-path> <noteId> <topic> <docType> <title> [--folder-title <title>]` を実行する。初回 topic だけ `--folder-title` を付ける。
6. 失敗時はエラーをそのまま報告して停止する。成功時は share URL だけを報告する。

アップロードは外部状態を変更するため、ユーザーが明示していない限り実行前に確認する。
