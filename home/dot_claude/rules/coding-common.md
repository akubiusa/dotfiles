---
paths:
  - "**/*.ts"
  - "**/*.tsx"
  - "**/*.js"
  - "**/*.jsx"
  - "**/*.mjs"
  - "**/*.cjs"
  - "**/*.py"
  - "**/*.go"
  - "**/*.rs"
  - "**/*.java"
  - "**/*.kt"
  - "**/*.swift"
  - "**/*.c"
  - "**/*.cpp"
  - "**/*.cs"
  - "**/*.rb"
  - "**/*.php"
  - "**/*.sh"
  - "**/*.bash"
---

# Common Coding Rules

Rules that apply regardless of language.

## All Languages

- Insert a half-width space between Japanese and alphanumeric characters in comments and text
- If existing error messages in a file have emoji prefixes, unify emoji usage across all error messages in that file
  - Use a single emoji that matches the content of the error message
- Content layer — each artifact carries one distinct layer of information; do not duplicate a layer into another artifact:
  - **Code** expresses *how*: the implementation steps themselves. If a comment is needed to understand the code, make the code clearer first instead of adding narration.
  - **Code comments** express *why not*: do not add comments by default.
    - Allowed only for: the reasoning behind the implementation choice (why this approach and not a rejected alternative), non-obvious constraints from the spec, security/performance/compatibility caveats, or assumptions likely to break in the future.
    - Never add: comments that restate what the code already shows, comments that only repeat what a function/variable name already makes obvious, "what" comments (e.g. "initialize the value", "increment the counter"), or temporary progress-report comments.
    - Never add: a reference to a GitHub Issue/PR number or a spec/plan file path as the comment's justification — the tracker item can be renamed, closed, or deleted independently of the code, leaving the comment unverifiable.
    - When stating a why-not conclusion, keep only the conclusion itself — drop the quantitative process behind it (sample counts, percentages, corpus sizes, benchmark numbers, verification steps), since that detail goes stale independently of the code and cannot be re-verified later.
    - If a single sentence needs more than one line break to fit, shorten the sentence itself instead of adding another break point — a sentence that keeps needing new breaks should be split into shorter sentences, not wrapped further.
    - Before finishing a task, review the comments you added or changed and remove any that fall under the "Never add" rules above.
  - **Test code** expresses *what*: test/spec names and assertions state the behavior being verified, not the internal implementation steps.
  - **Commit messages** express *why*: the description/body explains the motivation/reasoning for the change. The diff itself already shows *what* changed — do not restate it.
- Never leave edit-history notes (e.g. "Deleted X") in code — history belongs in commit messages / PRs

## Failure Handling

- Do not hide bugs behind fallbacks: no `config.port ?? 8080` for required config, no silent default in an "unreachable" branch — assert or throw instead.
- Never swallow an error (e.g. an empty catch block); catching is fine for cleanup, logging, or translating and rethrowing, but let errors that indicate programmer bugs propagate.
- Validate with strict schemas at IO boundaries (file, network, IPC, user input) and reject bad data with specifics instead of repairing it; past the boundary, trust the data.
- Every raised error names what went wrong and the offending value where useful (`Unknown effect type "reverb2"`, not `invalid input`); never include secrets or personal data, and truncate large values.
- A gate before a commit or other irreversible step must abort on failure (e.g. `check && commit` in shell, never `check; commit`; in other languages, throw or return explicitly before the commit).

## Testing

- Assert exact expected values, not loose predicates such as "contains 'error'"; for errors prefer the exception type, code, or structured fields, and match the message text exactly only when the message is part of the specified behavior.
- Never make a test pass by weakening its assertions; a failing test is information, so first decide whether the code or the test's expectation is wrong, and state why when you change the test.
- Every testable "never"/"always" invariant you claim about behavior should exist as a test (property-based where the input domain allows).
- A comparison or golden-output test must be sensitive to the behavior under test: inspect what the fixture actually produces and confirm a plausible bug would change it.
- Every test run must be bounded and exit; leave no watch modes, dev servers, or background processes behind.

## Editing

- Do not do mass edits with a regex; searching by pattern is fine, but read and change each site deliberately, since identical text can mean different things.
- Before writing a new function or pattern, search for an existing one and reuse it; if you find two near-duplicates that the current change touches, unify them; otherwise note them as a separate task.
- When replacing code, remove the old code in the same commit (no commented-out blocks, `-old`/`-v2` files, or unused exports), unless a staged migration or backward-compatibility window requires both; then record the removal plan.
- Do not add an abstraction until a second real use exists, and do not add options or fallback paths that nothing uses.
- Do not bypass static checks or safety guarantees (unchecked casts, `# type: ignore`, `unsafe`) without a comment stating why it is safe; TypeScript `any` is governed by `coding-ts.md`.
- Stage explicit paths when committing (no `git add -A` / `git add .`) and read `git status` first.
