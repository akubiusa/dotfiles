---
id: g
name: performance-errors-types
title: Performance / error handling / type design and tests
applies_to: all
---

## Scope

Check for:

- **Performance**:
  - Unnecessary loops, duplicate queries (N+1), etc.
  - Impact on hot paths or background jobs
  - Synchronous operations that could easily be async
- **Error handling / silent failures**:
  - Swallowed errors (empty catch blocks, `|| true`, etc.)
  - Inappropriate fallbacks that hide real failures
  - Loss of error information (discarded stack traces, etc.)
- **Type design / tests**:
  - Type invariants not expressed correctly (null/undefined leaking into types, etc.)
  - Missing tests for new features or critical paths — only when CLAUDE.md explicitly requires tests

Tag each finding's `title` with the sub-perspective it belongs to (performance, error handling, or type design/tests).
