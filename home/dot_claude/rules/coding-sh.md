---
paths:
  - "**/*.sh"
  - "**/*.bash"
---

# Shell Script Coding Rules

## Documentation

- Write a function description comment only when it adds contract value (usage, side effects, exit status); omit it when it would only restate the function name. Language: follow the repository language convention

## Error Messages

- Write error messages in English

## Formatting

- Indent with 4 spaces

## Shebang

- Use `#!/bin/bash` (use `#!/bin/sh` only when POSIX sh is sufficient)
