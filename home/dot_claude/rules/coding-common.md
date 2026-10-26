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
  - **Code comments** express *why not*: aim for zero code comments by default. When a comment seems necessary, first try to express it through naming, types, structure, or tests.
    - Keep a comment only when the code cannot show a reason, constraint, dangerous assumption, or why-not that would cause a mistake in a future change. Write only the conclusion, in 1-2 lines as a guideline.
    - Never add: comments that restate what the code does or what a name already makes obvious (e.g. "get the timeout from config", "increase the retry count"), narration of the work, edit history (e.g. "Deleted X" — history belongs in commit messages / PRs), or deliberation. Do not add a comment only to explain a rejected alternative.
    - Never add: a reference to a GitHub Issue/PR number or a spec/plan file path as the comment's justification — the tracker item can be renamed, closed, or deleted independently of the code, leaving the comment unverifiable.
    - When stating a why-not conclusion, keep only the conclusion itself — drop the quantitative process behind it (sample counts, percentages, corpus sizes, benchmark numbers, verification steps), since that detail goes stale independently of the code and cannot be re-verified later.
    - If a single sentence needs more than one line break to fit, shorten the sentence itself instead of adding another break point — a sentence that keeps needing new breaks should be split into shorter sentences, not wrapped further.
    - Before finishing a task, review the comments you added or changed and remove any that fall under the "Never add" rules above.
    - Out of scope for these rules: machine-readable comments a tool requires (e.g. the version comment on a SHA-pinned GitHub Action) and the stated reason for a lint or type-check suppression.
  - **JSDoc / docstrings** state the API contract for users of the interface, distinct from implementation comments: preconditions, meaning of arguments and return values, side effects, exceptions, units, as needed. Not for every function; omit it when it would only restate the name or type.
  - **Test code** expresses *what*: test/spec names and assertions state the behavior being verified, not the internal implementation steps.
  - **Commit messages** express *why*: the description/body explains the motivation/reasoning for the change. The diff itself already shows *what* changed — do not restate it.
  - **Issue / PR** record design decisions, rejected alternatives, verification results, and unverified items.
  - **Docs**: README / ops docs cover usage, configuration, operations, and incident response; ADRs hold long-term design decisions with alternatives and trade-offs; AGENTS.md / CLAUDE.md hold shared agent rules, verification procedures, and references to the canonical source.
- Keep one canonical source per piece of information and reference it elsewhere instead of copying it. The layers above indicate the primary responsibility and are not exclusive.

## Failure Handling

- Do not hide bugs behind fallbacks: no `config.port ?? 8080` for required config, no silent default in an "unreachable" branch — assert or throw instead.
- Never write an empty catch block, and do not catch errors that indicate programmer bugs.
- Validate with strict schemas at IO boundaries (file, network, IPC, user input) and reject bad data with specifics instead of repairing it; past the boundary, trust the data.
- Every raised error names what went wrong and the offending values (`Unknown effect type "reverb2"`, not `invalid input`).
- Gate-then-commit chains must abort on failure: `check && commit`, never `check; commit`.

## Testing

- Assert exact expected values and exact error messages, not loose predicates such as "contains 'error'".
- Never make a test pass by weakening its assertions; a failing test is information, so first decide whether the code or the test's expectation is wrong, and state why when you change the test.
- Every "never"/"always" claim in a comment or commit message should exist as a test (property-based where the input domain allows).
- A comparison or golden-output test must be sensitive to the behavior under test: inspect what the fixture actually produces and confirm a plausible bug would change it.
- Every test run must be bounded and exit; leave no watch modes, dev servers, or background processes behind.

## Editing

- Do not do mass edits with a regex; searching by pattern is fine, but read and change each site deliberately, since identical text can mean different things.
- Before writing a new function or pattern, search for an existing one and reuse it; if you find two near-duplicates, unifying them is part of the task.
- When replacing code, remove the old code in the same commit (no commented-out blocks, `-old`/`-v2` files, or unused exports).
- Do not add an abstraction until a second real use exists, and do not add options or fallback paths that nothing uses.
- Outside TypeScript (where `coding-ts.md` governs `any`), do not silence the type checker (unchecked casts, `unsafe`, `# type: ignore`) without a comment stating why it is safe.
- Stage explicit paths when committing (no `git add -A` / `git add .`) and read `git status` first.
