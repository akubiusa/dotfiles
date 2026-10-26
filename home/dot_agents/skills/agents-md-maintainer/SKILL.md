---
name: agents-md-maintainer
description: Use to create and maintain a project's AGENTS.md against the actual state of the project and Codex's official best practices. Use when asked to create a new AGENTS.md, update outdated procedures, or tidy up instructions.
---

# AGENTS.md Maintainer

`$agents-md-maintainer [directory]`. If omitted, target the current directory.

1. Confirm that the target directory exists and is readable, and read the README, the main manifests, the test and lint commands, the layout, and any existing `AGENTS.md`.
2. Extract only the build, test, format, and deploy commands that actually exist, plus generated artifacts, structure, constraints, and review criteria. Do not keep nonexistent commands or stale paths.
3. As durable guidance for Codex, concisely describe the repository-specific work procedures, safety constraints, and completion criteria. Split broad procedures out into skills, and put subdirectory-specific rules in the nearer `AGENTS.md`.
4. If half or more of the applicable major categories are missing, the structure is broken, or there are multiple statements that differ from reality, rewrite the whole document. Otherwise update only the sections that need it. If no document exists, create one. Always preserve an existing language-policy section; an `AGENTS.md` that contains only a language policy is not "missing categories", so leave it as is unless the user asks to extend it.
5. Prefer the repository's language policy for the body language. Only when there is no such policy, keep the existing document's language; if neither exists, ask the user (if non-interactive, hold off and report). After the change, report the approach, the rationale, the main changes, and how it was verified.
