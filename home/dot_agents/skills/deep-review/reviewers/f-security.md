---
id: f
name: security
title: Security
applies_to: all
---

## Scope

Examine changed trust boundaries for injection, path traversal, authorization bypass, secret exposure, unsafe deserialization, and insecure defaults. Tie every finding to an attacker-controlled input and a reachable sink.

Check for:

- Missing input validation / sanitisation (XSS, SQL injection, etc.)
- Authorisation checks missing or at the wrong layer
- Hardcoded secrets, tokens, or API keys; sensitive data in logs
- **AI-PR specific risks:**
  - Unvalidated external input interpolated into prompts (prompt injection)
  - GitHub tokens with over-broad scopes
  - Model output executed as shell commands without validation
