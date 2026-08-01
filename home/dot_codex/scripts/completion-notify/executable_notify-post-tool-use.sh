#!/bin/bash
# Cancel a pending permission notification once a tool has run.

set -euo pipefail

INPUT_JSON=$(cat)
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT_JSON")
[[ -n "$SESSION_ID" ]] || exit 0

DATA_DIR="$HOME/.codex/scripts/completion-notify/data"
rm -f "$DATA_DIR/pending-permission-${SESSION_ID}"
