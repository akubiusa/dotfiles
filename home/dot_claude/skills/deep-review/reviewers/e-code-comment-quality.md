---
id: e
name: code-comment-quality
title: Code-comment quality
applies_to: all
---

## Scope

Read code comments and docstrings in changed files. These checks are explicitly in scope for this agent, so the shared "general code quality concerns" suppression in SKILL.md does not apply to them. Flag:

- Cases where the implementation contradicts what a comment describes.
- Redundant comments that merely restate what the code already makes obvious (e.g. a comment saying "increment i by 1" directly above `i++`).
- Comments prone to becoming stale — descriptions of specific values, counts, enumerated lists, or implementation details duplicated from the code, which are likely to drift out of sync when the code changes.

If the same redundant/stale-prone pattern repeats many times in the diff, report it once with one or two representative `file:line` examples rather than listing every occurrence.
