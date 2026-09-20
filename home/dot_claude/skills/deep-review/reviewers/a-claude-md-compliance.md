---
id: a
name: claude-md-compliance
title: CLAUDE.md compliance
applies_to: all
---

## Scope

Read the CLAUDE.md and rules files. Flag violations of instructions that are explicitly stated there. Remember: CLAUDE.md is guidance for Claude writing code, so not every rule applies during review. Only flag what CLAUDE.md explicitly calls out.

Only cite rules tagged `repo` as the basis of a finding. Rules tagged `personal` (from `~/.claude/rules/`) guide how you work and write; never cite them as a finding basis, and set `rule_source` accordingly (`personal` only when a personal rule is the sole basis).
