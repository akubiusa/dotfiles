---
name: trilium
description: Use to upload a local Markdown document not tied to a GitHub Issue to self-hosted Trilium via ETAPI.
---

# Trilium Document Upload

1. Do not use this for documents tied to an Issue; post those as an Issue comment instead.
2. Validate `noteId` as `[a-zA-Z0-9_]{4,32}`, `topic` as `[a-zA-Z0-9_-]{1,25}`, and `docType` as one of `spec` / `plan` / `investigation`.
3. Before uploading, run `bash ~/bin/trilium-search.sh <topic>`, and if a document already exists, ask the user whether to revise it or create a new one.
4. Confirm that the document contains no API token, password, internal URL, or credentials.
5. Run `bash ~/bin/trilium-upload.sh <file-path> <noteId> <topic> <docType> <title> [--folder-title <title>]`. Add `--folder-title` only for the first document of a topic.
6. On failure, report the error as is and stop. On success, report only the share URL.

Uploading changes external state, so confirm with the user before running it unless they have explicitly asked for it.
