---
id: a
name: instruction-compliance
title: Repository Instruction Compliance
applies_to: all
---

## Scope

Read the applicable `CLAUDE.md`, `AGENTS.md`, and repository rules files. Flag violations of instructions that are explicitly stated there. Remember: these files are guidance for the assistant writing code, so not every rule applies during review — only flag what is explicitly called out. Report only concrete violations introduced by changed lines, citing both the instruction and `path:line`.

Only cite rules tagged `repo` as the basis of a finding. Rules tagged `personal` guide how you work and write; never cite them as a finding basis.
