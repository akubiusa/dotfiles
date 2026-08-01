---
id: h
name: error-handling
title: Error Handling / Silent Failures
applies_to: all
---

## Scope

Check failures, timeouts, cancellation, cleanup, retries, and diagnostics introduced by the change. Report only paths where an error is lost, incorrectly handled, or leaves unsafe/inconsistent state.

Check for:

- Swallowed errors (empty catch blocks, `|| true`, etc.)
- Inappropriate fallbacks that hide real failures
- Loss of error information (discarded stack traces, etc.)
