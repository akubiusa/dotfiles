#!/usr/bin/env bash

# PR monitor の durable state、lease、observer 境界を GitHub API stub で検証する。
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STATE_SCRIPT="$ROOT_DIR/home/dot_agents/skills/pr-health-monitor/scripts/executable_pr-monitor-state.sh"
WATCH_SCRIPT="$ROOT_DIR/home/dot_agents/skills/pr-health-monitor/scripts/executable_watch-pr.sh"
DISPATCH_SCRIPT="$ROOT_DIR/home/dot_agents/skills/pr-health-monitor/scripts/executable_pr-monitor-dispatch.sh"
COPILOT_SCRIPT="$ROOT_DIR/home/dot_agents/skills/pr-health-monitor/scripts/executable_wait-for-copilot-review.sh"
RESUME_SKILL="$ROOT_DIR/home/dot_agents/skills/resume-pr-monitor/SKILL.md"
TEST_DIR=$(mktemp -d)
TEST_HOME="$TEST_DIR/home"
TEST_BIN="$TEST_DIR/bin"
PR_URL="https://github.com/example/repo/pull/42"
SLEEP_PID=""

cleanup() {
    if [[ -n "$SLEEP_PID" ]]; then
        kill "$SLEEP_PID" 2>/dev/null || true
        wait "$SLEEP_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

mkdir -p "$TEST_HOME" "$TEST_BIN"
export HOME="$TEST_HOME"
export XDG_STATE_HOME="$TEST_DIR/state"
export PATH="$TEST_BIN:$PATH"

cat > "$TEST_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "display-message" ]]; then
    printf '%%77\n'
    exit 0
fi
if [[ "$1" == "send-keys" ]]; then
    printf '%s\n' "$*" >> "$TEST_DIR/tmux.log"
    exit 0
fi
exit 1
EOF
chmod +x "$TEST_BIN/tmux"

cat > "$TEST_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${GH_STUB_FAILURE:-0}" == "1" ]]; then
    exit 1
fi

case "$1 $2" in
    "pr view")
        if [[ "${GH_STUB_OPEN:-0}" == "1" ]]; then
            printf '%s\n' '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","url":"https://github.com/example/repo/pull/42"}'
        else
            printf '%s\n' '{"state":"MERGED","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","url":"https://github.com/example/repo/pull/42"}'
        fi
        ;;
    "pr checks")
        printf '%s\n' '[{"name":"unit","bucket":"fail","link":"https://github.com/example/repo/actions/runs/123"}]'
        exit 1
        ;;
    "api graphql")
        printf '%s\n' '1'
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TEST_BIN/gh"

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        echo "❌ Expected failure: $*" >&2
        exit 1
    fi
}

process_identity() {
    local pid="$1" started

    started=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | sed -E 's/^[[:space:]]+//; s/[[:space:]]+/ /g' || true)
    if [[ -n "$started" ]]; then
        printf 'ps-lstart:%s\n' "$started"
        return 0
    fi
    started=$(LC_ALL=C ps -p "$pid" -o start= 2>/dev/null | sed -E 's/^[[:space:]]+//; s/[[:space:]]+/ /g' || true)
    if [[ -n "$started" ]]; then
        printf 'ps-start:%s\n' "$started"
        return 0
    fi
    awk '{print "proc-start:" $22}' "/proc/$pid/stat" 2>/dev/null
}

echo "Testing PR monitor script syntax..."
bash -n "$STATE_SCRIPT"
bash -n "$WATCH_SCRIPT"
bash -n "$DISPATCH_SCRIPT"

echo "Testing absolute state directory and collision-resistant keys..."
expect_failure env XDG_STATE_HOME=relative HOME="$TEST_HOME" "$STATE_SCRIPT" init --pr-url "$PR_URL"
ID_DASH=$("$STATE_SCRIPT" id --pr-url "https://github.com/example/repo-a/pull/42")
ID_DOT=$("$STATE_SCRIPT" id --pr-url "https://github.com/example/repo.a/pull/42")
if [[ "$ID_DASH" == "$ID_DOT" || ! "$ID_DASH" =~ ^[a-f0-9]{64}$ ]]; then
    echo "❌ Canonical PR URLs do not have collision-resistant state keys" >&2
    exit 1
fi

echo "Testing state URL verification and stale/live lock recovery..."
"$STATE_SCRIPT" init --pr-url "$PR_URL" >/dev/null

echo "Testing registered ready pane receives only the fixed resume prompt..."
"$STATE_SCRIPT" register-pane --pr-url "$PR_URL" --pane %77 --nonce 0123456789abcdef >/dev/null
"$STATE_SCRIPT" pane-status --pr-url "$PR_URL" --nonce 0123456789abcdef --session-id session-42 --status ready
UNTRUSTED_RUN_URL="https://example.invalid/\$(injected)"
EXPECTED_DELIVERY="send-keys -t %77 -l -- \$resume-pr-monitor https://github.com/example/repo/pull/42 --event-id ci_failure:1"
"$STATE_SCRIPT" transition --pr-url "$PR_URL" --event ci --value failed --run-url "$UNTRUSTED_RUN_URL"
TEST_DIR="$TEST_DIR" "$DISPATCH_SCRIPT" --pr-url "$PR_URL"
if [[ "$(wc -l < "$TEST_DIR/tmux.log" | tr -d ' ')" != "2" ]] \
    || ! grep -Fxq "$EXPECTED_DELIVERY" "$TEST_DIR/tmux.log" \
    || ! grep -Fxq 'send-keys -t %77 Enter' "$TEST_DIR/tmux.log" \
    || grep -Fq 'injected' "$TEST_DIR/tmux.log"; then
    echo "❌ Dispatcher did not safely deliver the fixed resume prompt" >&2
    exit 1
fi
"$STATE_SCRIPT" transition --pr-url "$PR_URL" --event ci --value ok
"$STATE_SCRIPT" transition --pr-url "$PR_URL" --event ci --value failed --run-url "$UNTRUSTED_RUN_URL"
if [[ "$("$STATE_SCRIPT" show --pr-url "$PR_URL" | jq -r '.events.ci_failure.id')" != "ci_failure:2" ]]; then
    echo "❌ Repeated CI failures did not receive a distinct event ID" >&2
    exit 1
fi
"$STATE_SCRIPT" pane-status --pr-url "$PR_URL" --nonce 0123456789abcdef --session-id session-42 --status approval_pending
TEST_DIR="$TEST_DIR" "$DISPATCH_SCRIPT" --pr-url "$PR_URL"
if [[ "$(wc -l < "$TEST_DIR/tmux.log" | tr -d ' ')" != "2" ]]; then
    echo "❌ Dispatcher sent to an approval-pending pane" >&2
    exit 1
fi
"$STATE_SCRIPT" pane-status --pr-url "$PR_URL" --nonce 0123456789abcdef --session-id session-42 --status ready
"$STATE_SCRIPT" transition --pr-url "$PR_URL" --event close --value MERGED
TEST_DIR="$TEST_DIR" "$DISPATCH_SCRIPT" --pr-url "$PR_URL"
EXPECTED_CLOSE_DELIVERY="send-keys -t %77 -l -- \$resume-pr-monitor https://github.com/example/repo/pull/42 --event-id close:1"
if ! grep -Fxq "$EXPECTED_CLOSE_DELIVERY" "$TEST_DIR/tmux.log"; then
    echo "❌ Dispatcher did not deliver the pending close event" >&2
    exit 1
fi
STATE_ID=$("$STATE_SCRIPT" id --pr-url "$PR_URL")
STATE_FILE="$XDG_STATE_HOME/codex-pr-monitor/${STATE_ID}.json"
jq '.pr.url = "https://github.com/example/repo/pull/999"' "$STATE_FILE" > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"
expect_failure "$STATE_SCRIPT" show --pr-url "$PR_URL"
rm -f "$STATE_FILE"
"$STATE_SCRIPT" init --pr-url "$PR_URL" >/dev/null

LOCK_DIR="$XDG_STATE_HOME/codex-pr-monitor/${STATE_ID}.lock"
mkdir "$LOCK_DIR"
jq -n --arg token stale --argjson pid 999999 --argjson created "$(date +%s)" '{token: $token, pid: $pid, created_at_epoch: $created}' > "$LOCK_DIR/owner.json"
"$STATE_SCRIPT" transition --pr-url "$PR_URL" --event conflict --value clear

mkdir "$LOCK_DIR"
jq -n --arg token live --arg identity "$(process_identity "$$")" --argjson pid "$$" --argjson created "$(date +%s)" '{token: $token, pid: $pid, process_identity: $identity, created_at_epoch: $created}' > "$LOCK_DIR/owner.json"
expect_failure env PR_MONITOR_LOCK_ATTEMPTS=1 "$STATE_SCRIPT" transition --pr-url "$PR_URL" --event conflict --value conflicting
rm -f "$LOCK_DIR/owner.json"
rmdir "$LOCK_DIR"

sleep 30 &
SLEEP_PID=$!
mkdir "$LOCK_DIR"
jq -n --arg token unrelated --arg identity 'ps-lstart:wrong-process' --argjson pid "$SLEEP_PID" --argjson created 0 '{token: $token, pid: $pid, process_identity: $identity, created_at_epoch: $created}' > "$LOCK_DIR/owner.json"
"$STATE_SCRIPT" transition --pr-url "$PR_URL" --event conflict --value conflicting
if [[ -d "$LOCK_DIR" ]] || ! "$STATE_SCRIPT" show --pr-url "$PR_URL" | jq -e '.observed.conflict == "conflicting"' >/dev/null; then
    echo "❌ State mutation did not recover a live unrelated PID with mismatched identity" >&2
    exit 1
fi
kill "$SLEEP_PID" 2>/dev/null || true
wait "$SLEEP_PID" 2>/dev/null || true
SLEEP_PID=""

WATCH_LOCK="$XDG_STATE_HOME/codex-pr-monitor/${STATE_ID}.watch.lock"
sleep 30 &
SLEEP_PID=$!
mkdir "$WATCH_LOCK"
jq -n --arg token unrelated --arg identity 'ps-lstart:wrong-process' --argjson pid "$SLEEP_PID" --argjson created 0 '{token: $token, pid: $pid, process_identity: $identity, created_at_epoch: $created}' > "$WATCH_LOCK/owner.json"
PR_MONITOR_INTERVAL=0 "$WATCH_SCRIPT" watch --pr-url "$PR_URL"
if [[ -d "$WATCH_LOCK" ]]; then
    echo "❌ Watcher did not recover a live unrelated PID with mismatched identity" >&2
    exit 1
fi
kill "$SLEEP_PID" 2>/dev/null || true
wait "$SLEEP_PID" 2>/dev/null || true
SLEEP_PID=""

echo "Testing concurrent per-event claims and lease-safe acknowledgement..."
"$STATE_SCRIPT" transition --pr-url "$PR_URL" --event close --value MERGED
"$STATE_SCRIPT" claim --pr-url "$PR_URL" --event close --action cleanup --lease-id first
expect_failure "$STATE_SCRIPT" claim --pr-url "$PR_URL" --event close --action cleanup --lease-id second
expect_failure "$STATE_SCRIPT" ack --pr-url "$PR_URL" --event close --action cleanup --lease-id second
"$STATE_SCRIPT" release --pr-url "$PR_URL" --event close --action cleanup --lease-id first
"$STATE_SCRIPT" claim --pr-url "$PR_URL" --event close --action cleanup --lease-id second
"$STATE_SCRIPT" ack --pr-url "$PR_URL" --event close --action cleanup --lease-id second

"$STATE_SCRIPT" transition --pr-url "$PR_URL" --event ci --value failed --run-url https://github.com/example/repo/actions/runs/55
"$STATE_SCRIPT" claim --pr-url "$PR_URL" --event ci_failure --lease-id heartbeat --lease-seconds 1
"$STATE_SCRIPT" renew --pr-url "$PR_URL" --event ci_failure --lease-id heartbeat --lease-seconds 300
if ! "$STATE_SCRIPT" show --pr-url "$PR_URL" | jq -e '.events.ci_failure.lease.expires_at_epoch >= (now | floor) + 299' >/dev/null; then
    echo "❌ Lease heartbeat did not extend active action ownership" >&2
    exit 1
fi
expect_failure "$STATE_SCRIPT" claim --pr-url "$PR_URL" --event ci_failure --lease-id competing
"$STATE_SCRIPT" release --pr-url "$PR_URL" --event ci_failure --lease-id heartbeat
"$STATE_SCRIPT" transition --pr-url "$PR_URL" --event ci --value ok

"$STATE_SCRIPT" transition --pr-url "$PR_URL" --event copilot --value detected
("$STATE_SCRIPT" claim --pr-url "$PR_URL" --event copilot_review --lease-id parallel-one) > "$TEST_DIR/parallel-one.log" 2>&1 &
CLAIM_ONE_PID=$!
("$STATE_SCRIPT" claim --pr-url "$PR_URL" --event copilot_review --lease-id parallel-two) > "$TEST_DIR/parallel-two.log" 2>&1 &
CLAIM_TWO_PID=$!
CLAIM_SUCCESSES=0
if wait "$CLAIM_ONE_PID"; then
    CLAIM_SUCCESSES=$((CLAIM_SUCCESSES + 1))
fi
if wait "$CLAIM_TWO_PID"; then
    CLAIM_SUCCESSES=$((CLAIM_SUCCESSES + 1))
fi
if [[ "$CLAIM_SUCCESSES" -ne 1 ]]; then
    echo "❌ Concurrent resume claims did not elect exactly one owner" >&2
    exit 1
fi
if "$STATE_SCRIPT" show --pr-url "$PR_URL" | jq -e '.events.copilot_review.lease.id == "parallel-one"' >/dev/null; then
    "$STATE_SCRIPT" release --pr-url "$PR_URL" --event copilot_review --lease-id parallel-one
else
    "$STATE_SCRIPT" release --pr-url "$PR_URL" --event copilot_review --lease-id parallel-two
fi

echo "Testing reconciliation, actionable CI event, and terminal watcher exit..."
WATCH_LOCK="$XDG_STATE_HOME/codex-pr-monitor/${STATE_ID}.watch.lock"
mkdir "$WATCH_LOCK"
jq -n --arg token live --arg identity "$(process_identity "$$")" --argjson pid "$$" --argjson created "$(date +%s)" \
    '{token: $token, pid: $pid, process_identity: $identity, created_at_epoch: $created}' > "$WATCH_LOCK/owner.json"
"$STATE_SCRIPT" watcher --pr-url "$PR_URL" --pid "$$"
STATE_BEFORE_REUSE=$("$STATE_SCRIPT" show --pr-url "$PR_URL")
START_OUTPUT=$("$WATCH_SCRIPT" start --pr-url "$PR_URL")
STATE_AFTER_REUSE=$("$STATE_SCRIPT" show --pr-url "$PR_URL")
if [[ "$START_OUTPUT" != "reused $PR_URL" || "$STATE_AFTER_REUSE" != "$STATE_BEFORE_REUSE" ]]; then
    echo "❌ Watcher start did not preserve a live watcher state" >&2
    exit 1
fi
rm -f "$WATCH_LOCK/owner.json"
rmdir "$WATCH_LOCK"

if "$WATCH_SCRIPT" start --pr-url "$PR_URL" >/dev/null 2>&1; then
    echo "❌ Watcher start claimed detached monitoring" >&2
    exit 1
fi
if ! "$STATE_SCRIPT" show --pr-url "$PR_URL" | jq -e '.watcher.pid == null and .watcher.last_error == "foreground_required"' >/dev/null; then
    echo "❌ Foreground fallback did not persist a terminal diagnostic" >&2
    exit 1
fi
if [[ -d "$XDG_STATE_HOME/codex-pr-monitor/${STATE_ID}.watch.lock" ]]; then
    echo "❌ Foreground fallback left a watcher lock" >&2
    exit 1
fi
if rg -n 'nohup|systemd-run|setsid' "$WATCH_SCRIPT" >/dev/null; then
    echo "❌ Watcher still contains an unverified detached-launch path" >&2
    exit 1
fi

"$WATCH_SCRIPT" once --pr-url "$PR_URL"
if ! "$STATE_SCRIPT" show --pr-url "$PR_URL" | jq -e '.events.ci_failure.run_url == "https://github.com/example/repo/actions/runs/123" and .events.copilot_review.status == "pending"' >/dev/null; then
    echo "❌ Reconciliation did not atomically retain actionable CI and Copilot events" >&2
    exit 1
fi
if PR_MONITOR_INTERVAL=0 "$WATCH_SCRIPT" watch --pr-url "$PR_URL"; then
    :
fi
if ! "$STATE_SCRIPT" show --pr-url "$PR_URL" | jq -e '.watcher.pid == null and .events.close.value == "MERGED"' >/dev/null; then
    echo "❌ Terminal watcher did not enqueue final events and release itself" >&2
    exit 1
fi
if [[ -d "$XDG_STATE_HOME/codex-pr-monitor/${STATE_ID}.watch.lock" ]]; then
    echo "❌ Terminal watcher did not release its owned lock" >&2
    exit 1
fi

echo "Testing observer/action boundary and resume reconciliation contract..."
if grep -Eq 'tmux|handle-pr-reviews' "$COPILOT_SCRIPT"; then
    echo "❌ Copilot observer can still invoke an action processor" >&2
    exit 1
fi
if ! grep -Fq 'watch-pr.sh once --pr-url' "$RESUME_SKILL" \
    || ! grep -Fq 'claim --lease-id' "$RESUME_SKILL" \
    || ! grep -Fq 'watch-pr.sh watch --pr-url' "$RESUME_SKILL" \
    || ! grep -Fq 'foreground_required' "$RESUME_SKILL"; then
    echo "❌ Resume skill does not reconcile and document the foreground fallback" >&2
    exit 1
fi

echo "Testing five-failure stop state..."
if GH_STUB_FAILURE=1 PR_MONITOR_INTERVAL=0 PR_MONITOR_MAX_POLLS=5 "$WATCH_SCRIPT" watch --pr-url "$PR_URL"; then
    echo "❌ Watcher did not stop after five API failures" >&2
    exit 1
fi
if ! "$STATE_SCRIPT" show --pr-url "$PR_URL" | jq -e '.watcher.failures == 5 and .watcher.pid == null' >/dev/null; then
    echo "❌ Watcher did not persist the terminal API failure state" >&2
    exit 1
fi

echo "✅ PR monitor state and watcher tests passed"
