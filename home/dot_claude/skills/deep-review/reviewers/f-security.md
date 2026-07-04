---
id: f
name: security
title: Security
applies_to: all
---

## Scope

Check for:

- Missing input validation / sanitisation (XSS, SQL injection, etc.)
- Authorisation checks missing or at the wrong layer
- Hardcoded secrets, tokens, or API keys; sensitive data in logs
- **AI-PR specific risks:**
  - Unvalidated external input interpolated into prompts (prompt injection)
  - GitHub tokens with over-broad scopes
  - Model output executed as shell commands without validation
