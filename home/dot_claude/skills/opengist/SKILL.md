---
name: opengist
description: Upload a local Markdown document to self-hosted opengist via git push (HTTP for new gists, SSH for updates), for documents not tied to a GitHub Issue.
disable-model-invocation: false
user-invocable: false
---

# Upload a Document to opengist

Uploads a local Markdown document to the self-hosted opengist instance
(HTTP git push for new gists, SSH git push for updates to an existing
gist), for documents that are not tied to a GitHub Issue. Documents tied to
a GitHub Issue must instead follow `rules/issue-comment-docs.md` — that
case is out of scope for this skill.

## When to Apply

- `ticket-pr`'s requirements document.
- spec/plan/investigation documents not tied to a GitHub Issue (e.g.
  standalone brainstorming, pre-Issue discussions), per
  `rules/superpowers.md`'s spec/plan review workflow.

## Procedure

1. **Scope check**: if the document is tied to a GitHub Issue, stop and
   follow `rules/issue-comment-docs.md` instead — do not use this skill for
   that case.
2. **Determine the slug**: derive a deterministic slug from the caller's
   context. Examples:
   - Spec/plan not tied to a GitHub Issue: `spec-<topic-slug>` /
     `plan-<topic-slug>`.
   - `ticket-pr` requirements document: `requirements-<jira-ticket-key>`
     (lowercase; normalize any non `[a-z0-9-]` character to `-`).
   Reuse the same slug when the same document is revised later in the same
   session — re-running the upload with the same slug is treated as an
   update to the existing gist, not a new one.
3. **Check for sensitive information**: verify the document contains no
   secrets (tokens, passwords, internal URLs, credentials) before
   uploading — same check required before posting to GitHub Issues or Jira
   (see `rules/security.md`).
4. **Run the upload**:

   ```bash
   bash ~/bin/opengist-upload.sh <file-path> <slug> <title>
   ```

   On success, the gist URL is printed as the last line of stdout.
5. **On failure**: if the script exits non-zero, report the error output to
   the user as-is and let them decide how to proceed. There is no retry or
   fallback destination — per the operational policy from Issue #205's
   discussion, opengist is either reachable or it isn't.
6. **Reporting**: after a successful upload, report only the gist URL to
   the user. Do not paste the document body again in chat or in another
   comment (same policy as `rules/issue-comment-docs.md`).

## Notes

- The SSH host alias `opengist` is expected to already be configured by the
  user (`~/.ssh/config`); setting it up is out of scope for this skill.
- `~/.env` must contain `OPENGIST_HTTP_URL` and `OPENGIST_API_TOKEN` for
  new-gist creation (HTTP push); setting these up (including issuing the
  Personal Access Token via opengist's web UI) is out of scope for this
  skill.
- Uploaded content is still subject to `rules/security.md` — never include
  secrets.
