# Python, Shell, and Dockerfile Rules

## Python

- Use four-space indentation, docstrings for functions and classes, and the project-specified documentation language (otherwise English).
- Run `flake8 . --count --select=E1,E2,E3,E4,E7,E9,W1,W2,W3,W4,W5,F63,F7,F82 --show-source --statistics`; only the syntax and logic-error subset is mandatory.

## Shell

- Use four-space indentation and English error messages. Document functions in the project-specified language (otherwise English).
- Use `#!/bin/bash`; use `#!/bin/sh` only when POSIX shell is sufficient.

## Dockerfile

- Pass default hadolint rules. Use `book000/templates`' reusable hadolint workflow and do not add a dedicated hadolint configuration file.
