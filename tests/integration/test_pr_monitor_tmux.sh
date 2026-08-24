#!/bin/bash

# 実 tmux の delayed Enter が、ready 前の Enter を無視する composer へ resume prompt を送ることを確認する。
set -euo pipefail

if ! command -v tmux >/dev/null; then
    echo "SKIP: tmux is unavailable"
    exit 0
fi

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STATE="$ROOT_DIR/home/dot_agents/skills/pr-health-monitor/scripts/executable_pr-monitor-state.sh"
DISPATCH="$ROOT_DIR/home/dot_agents/skills/pr-health-monitor/scripts/executable_pr-monitor-dispatch.sh"
RESOLVER="$ROOT_DIR/home/dot_agents/skills/pr-health-monitor/scripts/executable_resolve-tmux-pane.sh"
DELAYED_COMPOSER="$ROOT_DIR/tests/fixtures/pr_monitor_delayed_composer.py"
TEST_DIR=$(mktemp -d)
SOCKET="pr-monitor-test-$$"
PR_URL="https://github.com/example/repo/pull/99"

cleanup() {
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

tmux -L "$SOCKET" new-session -d -s monitor "python3 '$DELAYED_COMPOSER' '$TEST_DIR/received'"
PANE=$(tmux -L "$SOCKET" display-message -p -t monitor:0.0 '#{pane_id}')
SOCKET_PATH=$(tmux -L "$SOCKET" display-message -p -t monitor:0.0 '#{socket_path}')

tmux -L "$SOCKET" new-session -d -s resolver
tmux -L "$SOCKET" split-window -t resolver
RESOLVER_PANE=$(tmux -L "$SOCKET" display-message -p -t resolver '#{pane_id}')
tmux -L "$SOCKET" send-keys -t resolver "env -u TMUX_PANE '$RESOLVER' > '$TEST_DIR/resolved-pane' 2> '$TEST_DIR/resolver-error'" Enter
for _ in {1..50}; do
    [[ -s "$TEST_DIR/resolved-pane" ]] && break
    sleep 0.1
done
if [[ "$(cat "$TEST_DIR/resolved-pane" 2>/dev/null || true)" != "$RESOLVER_PANE" ]]; then
    cat "$TEST_DIR/resolver-error" >&2 || true
    echo "❌ Resolver did not recover the unique pane with TMUX_PANE unset" >&2
    exit 1
fi
if UNRELATED_OUTPUT=$(env -u TMUX_PANE TMUX="$SOCKET_PATH,0,0" "$RESOLVER" 2>&1); then
    echo "❌ Resolver accepted a process outside every tmux pane: $UNRELATED_OUTPUT" >&2
    exit 1
fi
if [[ -n "$UNRELATED_OUTPUT" ]]; then
    echo "❌ Resolver emitted output for a process outside every tmux pane: $UNRELATED_OUTPUT" >&2
    exit 1
fi

HOME="$TEST_DIR/home" XDG_STATE_HOME="$TEST_DIR/state" "$STATE" init --pr-url "$PR_URL" >/dev/null
HOME="$TEST_DIR/home" XDG_STATE_HOME="$TEST_DIR/state" "$STATE" register-pane --pr-url "$PR_URL" --pane "$PANE" --nonce 0123456789abcdef
HOME="$TEST_DIR/home" XDG_STATE_HOME="$TEST_DIR/state" "$STATE" pane-status --pr-url "$PR_URL" --nonce 0123456789abcdef --session-id session-99 --status ready
HOME="$TEST_DIR/home" XDG_STATE_HOME="$TEST_DIR/state" "$STATE" transition --pr-url "$PR_URL" --event ci --value failed --run-url 'https://example.invalid/run'
TMUX="$SOCKET_PATH,0,0" HOME="$TEST_DIR/home" XDG_STATE_HOME="$TEST_DIR/state" PR_MONITOR_SUBMIT_DELAY_SECONDS=1.2 "$DISPATCH" --pr-url "$PR_URL"

for _ in {1..50}; do
    [[ -f "$TEST_DIR/received" ]] && break
    sleep 0.1
done
EXPECTED="\$resume-pr-monitor $PR_URL --event-id ci_failure:1"
if [[ "$(cat "$TEST_DIR/received" 2>/dev/null || true)" != "$EXPECTED" ]]; then
    echo "❌ Real tmux did not submit the expected delayed resume prompt" >&2
    exit 1
fi
TMUX="$SOCKET_PATH,0,0" HOME="$TEST_DIR/home" XDG_STATE_HOME="$TEST_DIR/state" PR_MONITOR_SUBMIT_DELAY_SECONDS=0 "$DISPATCH" --pr-url "$PR_URL"
if [[ "$(cat "$TEST_DIR/received")" != "$EXPECTED" ]]; then
    echo "❌ Real tmux dispatcher repeated an in-flight delivery" >&2
    exit 1
fi
echo "✅ Real tmux submitted one delayed resume prompt"
