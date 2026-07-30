---
name: trilium
description: Upload a local Markdown document to self-hosted Trilium via ETAPI, for documents not tied to a GitHub Issue.
disable-model-invocation: false
user-invocable: false
---

# Trilium Document Upload

Uploads a local Markdown document to the self-hosted Trilium Notes instance via its ETAPI,
for documents not tied to a GitHub Issue (`ticket-pr` requirements docs, standalone
investigations, spec/plan documents not posted as Issue comments).

## When to Apply

- Applies to: `ticket-pr` requirements documents, standalone investigations, spec/plan
  documents for work **not** tied to a GitHub Issue.
- Does not apply to: documents tied to a GitHub Issue — those follow
  `rules/issue-comment-docs.md` instead (posted directly as an Issue comment, no Trilium
  upload).

## Procedure

1. **Scope check**: confirm the document is not tied to a GitHub Issue (see "When to
   Apply" above). If it is, stop and follow `rules/issue-comment-docs.md` instead.
2. **Search for existing documents first**: run `bash ~/bin/trilium-search.sh <topic>`
   before uploading anything. If it reports existing hits, tell the user about them before
   proceeding — the upload may be a revision of one of those rather than a new document.
3. **Determine `noteId` / `topic` / `docType`**: the caller (this skill's invoker) is
   responsible for constructing these:
   - `noteId`: must match `^[a-zA-Z0-9_]{4,32}$`. Recommended (not required) convention:
     `<docType>_<topic正規化>`, e.g. `spec_twitter_acct`.
   - `topic`: a free-text project/topic identifier, reused across all documents for the
     same project so they land in the same folder and get cross-linked, e.g.
     `twitter-account-classifier`.
   - `docType`: one of `spec`, `plan`, `investigation`.
4. **Sensitive information check**: before uploading, verify the document contains no
   secrets (tokens, passwords, internal URLs, credentials) — same standard as
   `rules/security.md`.
5. **Run the upload**:
   `bash ~/bin/trilium-upload.sh <file-path> <noteId> <topic> <docType> <title> [--folder-title <title>]`
   and capture the share URL from its final line of stdout. `--folder-title` is required
   only the first time a given `topic` is uploaded (when its folder note doesn't exist
   yet) — omit it for subsequent uploads to the same `topic`.
6. **On failure**: if the script exits non-zero, report the error verbatim to the user and
   ask how to proceed. There is no retry or fallback destination.
7. **Reporting**: after a successful upload, report only the share URL to the user — do
   not paste the document body again in chat or elsewhere.
