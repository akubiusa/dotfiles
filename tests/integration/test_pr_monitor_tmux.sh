#!/bin/bash

# 実 tmux の literal send-keys が resume prompt だけを target pane へ渡すことを確認する。
set -euo pipefail

if ! command -v tmux >/dev/null; then
    echo "SKIP: tmux is unavailable"
    exit 0
fi

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STATE="$ROOT_DIR/home/dot_agents/skills/pr-health-monitor/scripts/executable_pr-monitor-state.sh"
DISPATCH="$ROOT_DIR/home/dot_agents/skills/pr-health-monitor/scripts/executable_pr-monitor-dispatch.sh"
TEST_DIR=$(mktemp -d)
SOCKET="pr-monitor-test-$$"
PR_URL="https://github.com/example/repo/pull/99"

cleanup() {
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

tmux -L "$SOCKET" new-session -d -s monitor "read line; printf '%s' \"\$line\" > '$TEST_DIR/received'; sleep 30"
PANE=$(tmux -L "$SOCKET" display-message -p -t monitor:0.0 '#{pane_id}')
SOCKET_PATH=$(tmux -L "$SOCKET" display-message -p -t monitor:0.0 '#{socket_path}')

HOME="$TEST_DIR/home" XDG_STATE_HOME="$TEST_DIR/state" "$STATE" init --pr-url "$PR_URL" >/dev/null
HOME="$TEST_DIR/home" XDG_STATE_HOME="$TEST_DIR/state" "$STATE" register-pane --pr-url "$PR_URL" --pane "$PANE" --nonce 0123456789abcdef
HOME="$TEST_DIR/home" XDG_STATE_HOME="$TEST_DIR/state" "$STATE" pane-status --pr-url "$PR_URL" --nonce 0123456789abcdef --session-id session-99 --status ready
HOME="$TEST_DIR/home" XDG_STATE_HOME="$TEST_DIR/state" "$STATE" transition --pr-url "$PR_URL" --event ci --value failed --run-url 'https://example.invalid/run'
TMUX="$SOCKET_PATH,0,0" HOME="$TEST_DIR/home" XDG_STATE_HOME="$TEST_DIR/state" "$DISPATCH" --pr-url "$PR_URL"

for _ in {1..50}; do
    [[ -f "$TEST_DIR/received" ]] && break
    sleep 0.1
done
EXPECTED="\$resume-pr-monitor $PR_URL --event-id ci_failure:1"
if [[ "$(cat "$TEST_DIR/received" 2>/dev/null || true)" != "$EXPECTED" ]]; then
    echo "❌ Real tmux did not deliver the expected literal resume prompt" >&2
    exit 1
fi
echo "✅ Real tmux delivered only the literal resume prompt"
