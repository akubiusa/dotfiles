# deep-review regression cases

Eight false or unverified claims from a real review (VCSpeaker.kt #451). Read before verifying a candidate: each case names the wrong claim, the check that was needed, and the correct classification.

## 1. Inherited serialized properties

- Wrong claim: a property is missing from serialization because the changed class does not declare it.
- Needed check: inspect the base classes and the serializer's rules for inherited properties on the project's library version.
- Correct classification: `out-of-scope` (false positive) when inherited properties are serialized; otherwise `merge-blocker` only with that evidence.

## 2. H2 AUTO_SERVER connection conditions

- Wrong claim: concurrent connections to the H2 database will fail.
- Needed check: whether the URL enables `AUTO_SERVER`, and what H2 does for that mode on the project's version (official docs or a minimal repro).
- Correct classification: `unverified` until the connection condition and version behavior are confirmed; `out-of-scope` if AUTO_SERVER covers the case.

## 3. Personal-rule contamination

- Wrong claim: a change violates a rule that comes from the reviewer's personal rules, presented as a project requirement.
- Needed check: whether the rule is stated in a repository `CLAUDE.md` / `AGENTS.md` and applies to the changed lines.
- Correct classification: `out-of-scope` on another author's PR; at most `follow-up` on the user's own PR; never `merge-blocker`; never cited in the comment.

## 4. Discord required options and authorization conditions

- Wrong claim: a slash-command option is required or a caller is unauthorized, so the command is broken or insecure.
- Needed check: the command definition's required options, the actual permission and role checks, and the conditions under which the handler runs.
- Correct classification: `follow-up` or `out-of-scope` unless a concrete unauthorized path is traced; an authorization bypass is never called proven from possibility alone.

## 5. Autocomplete-dependent cross-guild operations

- Wrong claim: an operation can act on another guild's data.
- Needed check: whether the target value can only come from autocomplete (scoped to the current guild) or is validated server-side; trace what a hand-typed value reaches.
- Correct classification: `merge-blocker` only if a user-supplied value reaches another guild's data without validation; `out-of-scope` if the handler scopes it.

## 6. Async rename and DB consistency

- Wrong claim: an asynchronous rename leaves the database inconsistent.
- Needed check: ordering and failure paths between the rename and the DB write, retry behavior, and the DB state after each failure.
- Correct classification: `merge-blocker` only with a concrete failing sequence and resulting inconsistency; `unverified` if the sequence cannot be shown.

## 7. Markdown `||` in tables

- Wrong claim: an unescaped `||` in generated Markdown is fine (or a table row is fine) when it splits the row.
- Needed check: render the table; `|` inside a cell, including a code span, must be escaped as `\|`.
- Correct classification: an output-defect in the comment itself; the generator (`render-comment.sh`) must escape it and `validate-comment.sh` must catch it.

## 8. Finding-number auto-links

- Wrong claim: referring to a finding as `#12` in the comment is harmless.
- Needed check: GitHub auto-links `#<number>` to issues and PRs.
- Correct classification: an output-defect; refer to findings as `Finding 12`-style text without `#` (the generator emits `指摘12`), and let `validate-comment.sh` reject any `#<number>`.
