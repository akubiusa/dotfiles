#!/usr/bin/env bash

set -euo pipefail

REVIEWER="book000"

usage() {
  cat <<'EOF'
Usage: gh-pr-reviewer.sh <owner/repo>

Print the reviewer login to pass to `gh pr create --reviewer`, or print
nothing when no reviewer should be requested.
- Prints `book000` when the authenticated user is not `book000` and
  `book000` is a collaborator of <owner/repo>
- Prints nothing (exit 0) when the authenticated user is `book000`
  (the PR author cannot review their own PR) or when `book000` is not
  a collaborator (the reason is written to stderr)
- Exits 1 when the argument is malformed or `gh api user` fails
EOF
}

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 1
fi

REPO="$1"
if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "Error: Invalid repository \"$REPO\" (expected owner/repo)" >&2
  exit 1
fi

if ! AUTHOR=$(gh api user -q .login); then
  echo "Error: Could not resolve the authenticated GitHub user" >&2
  exit 1
fi

if [[ "$AUTHOR" == "$REVIEWER" ]]; then
  exit 0
fi

if ! gh api "repos/$REPO/collaborators/$REVIEWER" --silent 2>/dev/null; then
  echo "Skipping reviewer: $REVIEWER is not a collaborator of $REPO (or collaborators are not readable)" >&2
  exit 0
fi

printf '%s\n' "$REVIEWER"
