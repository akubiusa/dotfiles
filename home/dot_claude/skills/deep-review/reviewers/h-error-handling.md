---
id: h
name: error-handling
title: Error handling / silent failures
applies_to: all
---

## Scope

Check for:

- Swallowed errors (empty catch blocks, `|| true`, etc.)
- Inappropriate fallbacks that hide real failures
- Loss of error information (discarded stack traces, etc.)
