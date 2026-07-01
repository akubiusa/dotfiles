# Confluence Upload Rules

Rules for sharing user-facing Markdown deliverables via Confluence.

---

## When to Apply

Applies to Markdown documents created for the user to read or review as a deliverable:

- Investigation results
- Spec files (`docs/superpowers/specs/*.md`)
- Plan files (`docs/superpowers/plans/*.md`)
- Other standalone write-ups intended for the user, not for the codebase itself

Does not apply to commit messages, PR bodies, code comments, or other routine
Git/GitHub artifacts — only to documents whose primary purpose is to be read by the user.

## Procedure

1. **Resolve cloudId**: same approach as `ticket-pr`'s cloudId resolution — try the site
   hostname first, otherwise use `mcp__atlassian__getAccessibleAtlassianResources`.
2. **Determine space and parent page**: there is no fixed space or parent page configured.
   - If unknown for this session, ask the user via AskUserQuestion (space key/name, and
     parent page if any). Do not guess or fabricate a space key or page ID.
   - Once confirmed in a session, reuse the same space/parent for subsequent uploads in
     that session without re-asking, unless the user indicates otherwise.
3. **Check for sensitive information**: verify the document contains no secrets (tokens,
   passwords, internal URLs, credentials) before uploading — same check already required
   before posting to GitHub Issues or Jira (see `rules/security.md`).
4. **Create the page** with `mcp__atlassian__createConfluencePage`:
   - `cloudId`, `spaceId`, `parentId` (if any), `title`, `body`, `contentFormat: "markdown"`.
   - Title convention: `<doc type> - <topic>`, e.g. `Investigation - <topic>`,
     `Spec - Issue #<number> <title>`, `Plan - Issue #<number> <title>`. Use whatever
     language the document itself is written in for `<topic>`/`<title>`; keep `<doc type>`
     in English so the title convention stated here stays consistent with this rule file.
5. **Update instead of duplicating**: if the document is revised later in the same session
   (e.g. after sub-agent review feedback or user comments), reuse the page created in step 4
   and call `mcp__atlassian__updateConfluencePage` with its `pageId` instead of creating a
   new page.
6. **Present the URL, not the content**: report the resulting Confluence page URL to the
   user. Do not paste the full document body again in chat or in an Issue/ticket comment —
   a short summary plus the Confluence URL is sufficient.

## Interaction with Other Skills

- **`issue-pr` / `ticket-pr` (Phase 6)**: after uploading the requirements document to
  Confluence, the GitHub Issue comment / Jira ticket comment must contain the Confluence
  URL plus a short summary only — not the full document body. (`issue-pr`'s phase number
  for this is deliberately not pinned here — its upload and comment phases are split
  across multiple phases and renumber independently of this rule; see its own SKILL.md
  for the current phase numbers.)
- **`rules/superpowers.md` spec/plan review workflow**: after the sub-agent review is
  complete, upload the reviewed document to Confluence before presenting it to the user, and
  give the user the Confluence URL alongside the local file path.

## Notes

- If MCP resolution (cloudId, space, page) fails, report the error to the user and ask how
  to proceed rather than guessing.
- Uploaded content is still subject to `rules/security.md` — never include secrets.
