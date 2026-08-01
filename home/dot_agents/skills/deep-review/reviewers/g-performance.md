---
id: g
name: performance
title: Performance
applies_to: all
---

## Scope

Identify material regressions in algorithmic complexity, repeated I/O, unbounded memory, hot paths, or avoidable network calls introduced by the change. Include the workload under which it matters.

Check for:

- Unnecessary loops, duplicate queries (N+1), etc.
- Impact on hot paths or background jobs
- Synchronous operations that could easily be async
