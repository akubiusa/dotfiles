---
id: g
name: performance-errors-types
title: Performance, Error Handling, Type Design and Tests
applies_to: all
---

## Scope

Identify material regressions in algorithmic complexity, repeated I/O, unbounded memory, hot paths, or avoidable network calls introduced by the change. Include the workload under which it matters.

Check failures, timeouts, cancellation, cleanup, retries, and diagnostics introduced by the change. Report only paths where an error is lost, incorrectly handled, or leaves unsafe/inconsistent state.

Check changed APIs, type boundaries, validation, and tests for cases that allow invalid state or leave a changed behavior unprotected. Do not request generic test coverage; identify a specific missing test or type constraint.

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
  - Missing tests for new features or critical paths — only when CLAUDE.md/AGENTS.md explicitly requires tests

Tag each finding's `title` with the sub-perspective it belongs to (performance, error handling, or type design/tests).
