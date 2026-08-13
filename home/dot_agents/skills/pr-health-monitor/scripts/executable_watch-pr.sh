#!/usr/bin/env bash

# この watcher は GitHub を観測して durable event を記録するだけで、action は実行しない。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE_HELPER="$SCRIPT_DIR/pr-monitor-state.sh"
[[ -x "$STATE_HELPER" ]] || STATE_HELPER="$SCRIPT_DIR/executable_pr-monitor-state.sh"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
[[ "$STATE_HOME" == /* ]] || { echo "Error: XDG_STATE_HOME must be an absolute path" >&2; exit 1; }
STATE_DIR="$STATE_HOME/codex-pr-monitor"
LOG_DIR="$HOME/.codex/logs"
INTERVAL="${PR_MONITOR_INTERVAL:-30}"
MAX_POLLS="${PR_MONITOR_MAX_POLLS:-0}"
LOCK_STALE_SECONDS="${PR_MONITOR_LOCK_STALE_SECONDS:-21600}"
LOCK_ATTEMPTS="${PR_MONITOR_LOCK_ATTEMPTS:-100}"
[[ "$LOCK_STALE_SECONDS" =~ ^[0-9]+$ && "$LOCK_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || { echo "Error: Invalid PR monitor lock configuration" >&2; exit 1; }
umask 077
mkdir -p "$STATE_DIR" "$LOG_DIR"

usage() {
    echo "Usage: $0 <start|watch|once> --pr-url URL" >&2
    exit 1
}

COMMAND="${1:-}"
shift || true
PR_URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr-url)
            PR_URL="${2:-}"
            shift
            ;;
        *) usage ;;
    esac
    shift
done

[[ "$COMMAND" == "start" || "$COMMAND" == "watch" || "$COMMAND" == "once" ]] || usage
[[ -n "$PR_URL" ]] || usage
if [[ ! "$PR_URL" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)(/)?([?#].*)?$ ]]; then
    echo "Error: --pr-url must be a canonical GitHub PR URL" >&2
    exit 1
fi

OWNER="${BASH_REMATCH[1]}"
REPO="${BASH_REMATCH[2]}"
PR_NUMBER="${BASH_REMATCH[3]}"
PR_URL="https://github.com/${OWNER}/${REPO}/pull/${PR_NUMBER}"
[[ -x "$STATE_HELPER" ]] || { echo "Error: Missing PR monitor state helper" >&2; exit 1; }
"$STATE_HELPER" init --pr-url "$PR_URL" >/dev/null
STATE_ID=$("$STATE_HELPER" id --pr-url "$PR_URL")
WATCH_LOCK="$STATE_DIR/${STATE_ID}.watch.lock"
WATCH_GUARD_FILE="$STATE_DIR/${STATE_ID}.watch.guard"
LOG_FILE="$LOG_DIR/watch-pr-${STATE_ID}.log"
SUPERVISOR="$SCRIPT_DIR/pr-monitor-supervisor.sh"
[[ -x "$SUPERVISOR" ]] || SUPERVISOR="$SCRIPT_DIR/executable_pr-monitor-supervisor.sh"
WATCH_LOCK_OWNED=false
WATCH_GUARD_FD=""

state() {
    "$STATE_HELPER" "$@" --pr-url "$PR_URL"
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

    if [[ -r "/proc/$pid/stat" ]]; then
        started=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
        if [[ "$started" =~ ^[0-9]+$ ]]; then
            printf 'proc-start:%s\n' "$started"
            return 0
        fi
    fi

    return 1
}

watch_lock_is_live() {
    local pid identity current_identity now lock_mtime

    now=$(date +%s)
    if [[ ! -f "$WATCH_LOCK/owner.json" ]]; then
        lock_mtime=$(stat -c %Y "$WATCH_LOCK" 2>/dev/null || printf '0')
        if [[ "$lock_mtime" =~ ^[0-9]+$ ]] && (( now - lock_mtime <= 5 )); then
            return 0
        fi
        return 1
    fi
    pid=$(jq -r '.pid // empty' "$WATCH_LOCK/owner.json" 2>/dev/null || true)
    identity=$(jq -r '.process_identity // empty' "$WATCH_LOCK/owner.json" 2>/dev/null || true)
    [[ "$pid" =~ ^[0-9]+$ && -n "$identity" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    current_identity=$(process_identity "$pid" || true)
    [[ -n "$current_identity" && "$current_identity" == "$identity" ]]
}

recover_stale_watch_lock() {
    local stale_dir

    watch_lock_is_live && return 1
    stale_dir="$STATE_DIR/${STATE_ID}.watch.lock.stale.${BASHPID}.${RANDOM}"
    if mv "$WATCH_LOCK" "$stale_dir" 2>/dev/null; then
        rm -f "$stale_dir/owner.json"
        rmdir "$stale_dir" 2>/dev/null || true
        return 0
    fi
    return 1
}

acquire_watch_lock() {
    local _attempt now

    if [[ -z "$WATCH_GUARD_FD" ]]; then
        exec {WATCH_GUARD_FD}>"$WATCH_GUARD_FILE"
        if ! flock -w 5 "$WATCH_GUARD_FD"; then
            return 1
        fi
    fi

    WATCH_LOCK_TOKEN="${BASHPID}-$(date +%s)-${RANDOM}"
    for _attempt in $(seq 1 "$LOCK_ATTEMPTS"); do
        if mkdir "$WATCH_LOCK" 2>/dev/null; then
            now=$(date +%s)
            PROCESS_IDENTITY=$(process_identity "$BASHPID" || true)
            jq -n --arg token "$WATCH_LOCK_TOKEN" --arg identity "$PROCESS_IDENTITY" --argjson pid "$BASHPID" --argjson created "$now" \
                '{token: $token, pid: $pid, process_identity: $identity, created_at_epoch: $created}' > "$WATCH_LOCK/owner.json"
            WATCH_LOCK_OWNED=true
            return 0
        fi
        recover_stale_watch_lock || true
        sleep 0.05
    done
    return 1
}

release_watch_lock() {
    local token

    [[ "$WATCH_LOCK_OWNED" == true && -f "$WATCH_LOCK/owner.json" ]] || return 0
    token=$(jq -r '.token // empty' "$WATCH_LOCK/owner.json" 2>/dev/null || true)
    [[ "$token" == "$WATCH_LOCK_TOKEN" ]] || return 0
    rm -f "$WATCH_LOCK/owner.json"
    rmdir "$WATCH_LOCK" 2>/dev/null || true
    WATCH_LOCK_OWNED=false
    if [[ -n "$WATCH_GUARD_FD" ]]; then
        flock -u "$WATCH_GUARD_FD" 2>/dev/null || true
        exec {WATCH_GUARD_FD}>&-
        WATCH_GUARD_FD=""
    fi
}

cleanup() {
    state watcher --pid none || true
    release_watch_lock
}

# shellcheck disable=SC2016
COPILOT_QUERY='query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviews(first: 100) { nodes { author { login __typename } state submittedAt } }
    }
  }
}'

TERMINAL=false
observe_once() {
    local pr_json checks_json copilot_count failed_check_count run_url pr_state

    TERMINAL=false
    if ! pr_json=$(gh pr view "$PR_NUMBER" --repo "$OWNER/$REPO" --json state,mergeable,mergeStateStatus,url 2>> "$LOG_FILE"); then
        return 1
    fi
    if ! jq -e --arg url "$PR_URL" '.state and .url == $url' >/dev/null <<< "$pr_json"; then
        return 1
    fi
    pr_state=$(jq -r '.state' <<< "$pr_json")
    case "$pr_state" in
        MERGED|CLOSED)
            state transition --event close --value "$pr_state"
            TERMINAL=true
            ;;
    esac

    if [[ "$(jq -r '.mergeable // ""' <<< "$pr_json")" == "CONFLICTING" || "$(jq -r '.mergeStateStatus // ""' <<< "$pr_json")" == "DIRTY" ]]; then
        state transition --event conflict --value conflicting
    else
        state transition --event conflict --value clear
    fi

    if checks_json=$(gh pr checks "$PR_NUMBER" --repo "$OWNER/$REPO" --json name,bucket,link 2>> "$LOG_FILE"); then
        :
    elif ! jq -e 'type == "array"' >/dev/null <<< "$checks_json"; then
        return 1
    fi
    failed_check_count=$(jq '[.[] | select(.bucket == "fail" or .bucket == "cancel")] | length' <<< "$checks_json")
    if [[ "$failed_check_count" -gt 0 ]]; then
        run_url=$(jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel") | .link // empty] | first // ""' <<< "$checks_json")
        state transition --event ci --value failed --run-url "$run_url"
    else
        state transition --event ci --value ok
    fi

    if ! copilot_count=$(gh api graphql -f owner="$OWNER" -f repo="$REPO" -F number="$PR_NUMBER" -f query="$COPILOT_QUERY" --jq '[.data.repository.pullRequest.reviews.nodes[] | select(.author.__typename == "Bot" and (.author.login | ascii_downcase | contains("copilot")) and (.state == "COMMENTED" or .state == "APPROVED" or .state == "CHANGES_REQUESTED") and .submittedAt != null)] | length' 2>> "$LOG_FILE"); then
        return 1
    fi
    [[ "$copilot_count" =~ ^[0-9]+$ ]] || return 1
    if [[ "$copilot_count" -gt 0 ]]; then
        state transition --event copilot --value detected
    else
        state transition --event copilot --value none
    fi
}

if [[ "$COMMAND" == "once" ]]; then
    if observe_once; then
        state api-failure --count 0
        exit 0
    fi
    state api-failure --count 1
    exit 1
fi

if [[ "$COMMAND" == "start" ]]; then
    if [[ -d "$WATCH_LOCK" ]] && watch_lock_is_live; then
        echo "reused $PR_URL"
        exit 0
    fi
    if [[ -d "$WATCH_LOCK" ]]; then
        recover_stale_watch_lock || true
    fi
    runtime=$(state show)
    pane=$(jq -r '.runtime.pane // empty' <<< "$runtime")
    nonce=$(jq -r '.runtime.nonce // empty' <<< "$runtime")
    if [[ ! "$pane" =~ ^%[0-9]+$ || ! "$nonce" =~ ^[A-Za-z0-9_.-]{16,}$ ]] \
        || [[ "$(tmux display-message -p -t "$pane" '#{pane_id}' 2>/dev/null || true)" != "$pane" ]]; then
        state watcher-error --reason foreground_required || true
        state watcher --pid none || true
        echo "Error: tmux pane registration is unavailable. Run '$0 watch --pr-url $PR_URL' in a persistent terminal, or use '$SUPERVISOR --pr-url $PR_URL'." >&2
        exit 1
    fi
    window_name="codex-pr-monitor-${STATE_ID:0:12}"
    if ! tmux new-window -d -n "$window_name" "$SUPERVISOR --pr-url $PR_URL"; then
        state watcher-error --reason foreground_required || true
        state watcher --pid none || true
        echo "Error: Failed to create tmux monitor window. Use '$SUPERVISOR --pr-url $PR_URL'." >&2
        exit 1
    fi
    echo "started $PR_URL $window_name"
    exit 0
fi

if ! acquire_watch_lock; then
    echo "Already running for $PR_URL" >&2
    exit 0
fi
trap cleanup EXIT

FAILURES=0
POLLS=0
if ! state watcher --pid "$$"; then
    state watcher-error --reason initialization_failed || true
    echo "Error: Failed to record watcher readiness" >&2
    exit 1
fi
while :; do
    if observe_once; then
        FAILURES=0
        state api-failure --count 0
        if [[ "$TERMINAL" == true ]]; then
            exit 0
        fi
    else
        FAILURES=$((FAILURES + 1))
        state api-failure --count "$FAILURES"
        printf '[%s] API failure %s/5\n' "$(date -Iseconds)" "$FAILURES" >> "$LOG_FILE"
        if [[ "$FAILURES" -ge 5 ]]; then
            echo "Error: Stopping PR watcher after 5 consecutive API failures" >&2
            exit 1
        fi
    fi
    POLLS=$((POLLS + 1))
    if [[ "$MAX_POLLS" -gt 0 && "$POLLS" -ge "$MAX_POLLS" ]]; then
        exit 0
    fi
    sleep "$INTERVAL"
done
