#!/bin/bash

# observer と dispatcher を同じ tmux monitor window で管理する。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WATCH="$SCRIPT_DIR/watch-pr.sh"
DISPATCH="$SCRIPT_DIR/pr-monitor-dispatch.sh"
[[ -x "$WATCH" ]] || WATCH="$SCRIPT_DIR/executable_watch-pr.sh"
[[ -x "$DISPATCH" ]] || DISPATCH="$SCRIPT_DIR/executable_pr-monitor-dispatch.sh"
STATE="$SCRIPT_DIR/pr-monitor-state.sh"
[[ -x "$STATE" ]] || STATE="$SCRIPT_DIR/executable_pr-monitor-state.sh"

[[ "${1:-}" == "--pr-url" && -n "${2:-}" ]] || { echo "Usage: $0 --pr-url URL" >&2; exit 1; }
PR_URL="$2"

"$WATCH" watch --pr-url "$PR_URL" &
WATCH_PID=$!
cleanup() {
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

while :; do
    "$DISPATCH" --pr-url "$PR_URL" || true
    if ! kill -0 "$WATCH_PID" 2>/dev/null; then
        if ! "$STATE" pending --pr-url "$PR_URL" | grep -q .; then
            break
        fi
    fi
    sleep "${PR_MONITOR_INTERVAL:-30}"
done
wait "$WATCH_PID" || true
