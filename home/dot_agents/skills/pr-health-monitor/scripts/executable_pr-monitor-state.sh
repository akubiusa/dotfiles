#!/usr/bin/env bash

# PR 監視の状態を、実行可能な command ではなく最小限の event descriptor として保持する。
# shellcheck disable=SC2016
set -euo pipefail

STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
[[ "$STATE_HOME" == /* ]] || { echo "Error: XDG_STATE_HOME must be an absolute path" >&2; exit 1; }
STATE_DIR="$STATE_HOME/codex-pr-monitor"
LOCK_STALE_SECONDS="${PR_MONITOR_LOCK_STALE_SECONDS:-21600}"
LOCK_ATTEMPTS="${PR_MONITOR_LOCK_ATTEMPTS:-100}"
[[ "$LOCK_STALE_SECONDS" =~ ^[0-9]+$ && "$LOCK_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || { echo "Error: Invalid PR monitor lock configuration" >&2; exit 1; }
umask 077
mkdir -p "$STATE_DIR"

usage() {
    echo "Usage: $0 <init|id|show|pending|transition|claim|renew|ack|release|watcher|watcher-error|api-failure|register-pane|pane-status|unregister-pane> --pr-url URL [...]" >&2
    exit 1
}

COMMAND=""
PR_URL=""
EVENT=""
VALUE=""
ACTION=""
LEASE_ID=""
LEASE_SECONDS="300"
WATCHER_PID=""
FAILURE_COUNT=""
RUN_URL=""
WATCHER_REASON=""
TMUX_PANE=""
REGISTRATION_NONCE=""
SESSION_ID=""
PANE_STATUS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        init|id|show|pending|transition|claim|renew|ack|release|watcher|watcher-error|api-failure|register-pane|pane-status|unregister-pane)
            COMMAND="$1"
            ;;
        --pr-url)
            PR_URL="${2:-}"
            shift
            ;;
        --event)
            EVENT="${2:-}"
            shift
            ;;
        --value)
            VALUE="${2:-}"
            shift
            ;;
        --action)
            ACTION="${2:-}"
            shift
            ;;
        --lease-id)
            LEASE_ID="${2:-}"
            shift
            ;;
        --lease-seconds)
            LEASE_SECONDS="${2:-}"
            shift
            ;;
        --pid)
            WATCHER_PID="${2:-}"
            shift
            ;;
        --count)
            FAILURE_COUNT="${2:-}"
            shift
            ;;
        --run-url)
            RUN_URL="${2:-}"
            shift
            ;;
        --reason)
            WATCHER_REASON="${2:-}"
            shift
            ;;
        --pane)
            TMUX_PANE="${2:-}"
            shift
            ;;
        --nonce)
            REGISTRATION_NONCE="${2:-}"
            shift
            ;;
        --session-id)
            SESSION_ID="${2:-}"
            shift
            ;;
        --status)
            PANE_STATUS="${2:-}"
            shift
            ;;
        *)
            usage
            ;;
    esac
    shift
done

[[ -n "$COMMAND" && -n "$PR_URL" ]] || usage
if [[ ! "$PR_URL" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)(/)?([?#].*)?$ ]]; then
    echo "Error: --pr-url must be a canonical GitHub PR URL" >&2
    exit 1
fi

OWNER="${BASH_REMATCH[1]}"
REPO="${BASH_REMATCH[2]}"
PR_NUMBER="${BASH_REMATCH[3]}"
CANONICAL_PR_URL="https://github.com/${OWNER}/${REPO}/pull/${PR_NUMBER}"
STATE_ID=$(printf '%s' "$CANONICAL_PR_URL" | sha256sum | awk '{print $1}')
STATE_FILE="$STATE_DIR/${STATE_ID}.json"
LOCK_DIR="$STATE_DIR/${STATE_ID}.lock"
GUARD_FILE="$STATE_DIR/${STATE_ID}.guard"
LOCK_TOKEN="${BASHPID}-$(date +%s)-${RANDOM}"
LOCK_ACQUIRED=false
GUARD_FD=""

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

lock_owner_is_live() {
    local pid identity current_identity now lock_mtime

    now=$(date +%s)
    if [[ ! -f "$LOCK_DIR/owner.json" ]]; then
        lock_mtime=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || printf '0')
        if [[ "$lock_mtime" =~ ^[0-9]+$ ]] && (( now - lock_mtime <= 5 )); then
            return 0
        fi
        return 1
    fi
    pid=$(jq -r '.pid // empty' "$LOCK_DIR/owner.json" 2>/dev/null || true)
    identity=$(jq -r '.process_identity // empty' "$LOCK_DIR/owner.json" 2>/dev/null || true)
    [[ "$pid" =~ ^[0-9]+$ && -n "$identity" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    current_identity=$(process_identity "$pid" || true)
    [[ -n "$current_identity" && "$current_identity" == "$identity" ]]
}

recover_stale_lock() {
    local stale_dir

    lock_owner_is_live && return 1
    stale_dir="$STATE_DIR/${STATE_ID}.lock.stale.${BASHPID}.${RANDOM}"
    if mv "$LOCK_DIR" "$stale_dir" 2>/dev/null; then
        rm -f "$stale_dir/owner.json"
        rmdir "$stale_dir" 2>/dev/null || true
        return 0
    fi
    return 1
}

acquire_lock() {
    local _attempt now

    if [[ -z "$GUARD_FD" ]]; then
        exec {GUARD_FD}>"$GUARD_FILE"
        if ! flock -w 5 "$GUARD_FD"; then
            echo "Error: Timed out waiting for PR monitor guard lock" >&2
            exit 1
        fi
    fi

    for _attempt in $(seq 1 "$LOCK_ATTEMPTS"); do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            now=$(date +%s)
            PROCESS_IDENTITY=$(process_identity "$BASHPID" || true)
            jq -n --arg token "$LOCK_TOKEN" --arg identity "$PROCESS_IDENTITY" --argjson pid "$BASHPID" --argjson created "$now" \
                '{token: $token, pid: $pid, process_identity: $identity, created_at_epoch: $created}' > "$LOCK_DIR/owner.json"
            LOCK_ACQUIRED=true
            return 0
        fi
        recover_stale_lock || true
        sleep 0.05
    done

    echo "Error: Timed out waiting for PR monitor state lock" >&2
    exit 1
}

release_lock() {
    local token

    [[ "$LOCK_ACQUIRED" == true && -f "$LOCK_DIR/owner.json" ]] || return 0
    token=$(jq -r '.token // empty' "$LOCK_DIR/owner.json" 2>/dev/null || true)
    [[ "$token" == "$LOCK_TOKEN" ]] || return 0
    rm -f "$LOCK_DIR/owner.json"
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_ACQUIRED=false
    flock -u "$GUARD_FD" 2>/dev/null || true
    exec {GUARD_FD}>&-
    GUARD_FD=""
}
trap release_lock EXIT

verify_state() {
    [[ -f "$STATE_FILE" ]] || { echo "Error: PR monitor state does not exist; run init first" >&2; exit 1; }
    if ! jq -e --arg url "$CANONICAL_PR_URL" '(.version == 2 or .version == 3) and .pr.url == $url and .pr.owner != null and .pr.repo != null and .pr.number != null' "$STATE_FILE" >/dev/null; then
        echo "Error: PR monitor state does not match the canonical PR URL" >&2
        exit 1
    fi
}

write_state() {
    local filter="$1"
    shift
    local temp_file

    temp_file=$(mktemp "$STATE_DIR/.${STATE_ID}.XXXXXX")
    chmod 600 "$temp_file"
    if ! jq "$filter" "$@" "$STATE_FILE" > "$temp_file"; then
        rm -f "$temp_file"
        echo "Error: Failed to update PR monitor state" >&2
        exit 1
    fi
    mv "$temp_file" "$STATE_FILE"
}

event_path() {
    if [[ "$EVENT" == "close" ]]; then
        [[ "$ACTION" == "cleanup" || "$ACTION" == "glitchtip-resolve" ]] || usage
        printf '.events.close.actions["%s"]' "$ACTION"
    elif [[ "$EVENT" == "ci_failure" || "$EVENT" == "conflict" || "$EVENT" == "copilot_review" ]]; then
        printf '.events.%s' "$EVENT"
    else
        usage
    fi
}

case "$COMMAND" in
    init)
        acquire_lock
        if [[ ! -f "$STATE_FILE" ]]; then
            temp_file=$(mktemp "$STATE_DIR/.${STATE_ID}.XXXXXX")
            chmod 600 "$temp_file"
            jq -n --arg url "$CANONICAL_PR_URL" --arg owner "$OWNER" --arg repo "$REPO" --argjson number "$PR_NUMBER" \
                '{version: 3, pr: {url: $url, owner: $owner, repo: $repo, number: $number}, observed: {state: "OPEN", ci: "unknown", conflict: "unknown", copilot: "none"}, generations: {close: 0, ci_failure: 0, conflict: 0, copilot_review: 0}, events: {close: null, ci_failure: null, conflict: null, copilot_review: null}, watcher: {pid: null, failures: 0, updated_at: null, last_error: null}, runtime: {pane: null, nonce: null, session_id: null, status: "unregistered", updated_at: null}}' > "$temp_file"
            mv "$temp_file" "$STATE_FILE"
        else
            verify_state
        fi
        printf '%s\n' "$STATE_FILE"
        ;;
    id)
        printf '%s\n' "$STATE_ID"
        ;;
    show)
        verify_state
        cat "$STATE_FILE"
        ;;
    pending)
        verify_state
        jq -c '.events | to_entries[] | select(.value != null) | select(.value.status == "pending" or ((.value.actions? // {}) | any(.status == "pending"))) | {event: .key, data: .value}' "$STATE_FILE"
        ;;
    transition)
        verify_state
        [[ -n "$EVENT" && -n "$VALUE" ]] || usage
        NOW=$(date -Iseconds)
        acquire_lock
        verify_state
        case "$EVENT" in
            close)
                [[ "$VALUE" == "MERGED" || "$VALUE" == "CLOSED" ]] || { echo "Error: Invalid close value" >&2; exit 1; }
                write_state 'if .observed.state == $value then . else .observed.state = $value | .generations.close = ((.generations.close // 0) + 1) | .events.close = {id: ("close:" + (.generations.close | tostring)), status: "pending", value: $value, detected_at: $now, actions: {cleanup: {status: "pending", lease: null}, "glitchtip-resolve": {status: "not_applicable", lease: null}}} end' --arg value "$VALUE" --arg now "$NOW"
                ;;
            ci)
                [[ "$VALUE" == "failed" || "$VALUE" == "ok" ]] || { echo "Error: Invalid CI value" >&2; exit 1; }
                write_state 'if .observed.ci == $value then . else .observed.ci = $value | (if $value == "failed" then .generations.ci_failure = ((.generations.ci_failure // 0) + 1) | .events.ci_failure = {id: ("ci_failure:" + (.generations.ci_failure | tostring)), status: "pending", value: $value, detected_at: $now, run_url: $run_url, lease: null} else . end) end' --arg value "$VALUE" --arg now "$NOW" --arg run_url "$RUN_URL"
                ;;
            conflict)
                [[ "$VALUE" == "conflicting" || "$VALUE" == "clear" ]] || { echo "Error: Invalid conflict value" >&2; exit 1; }
                write_state 'if .observed.conflict == $value then . else .observed.conflict = $value | (if $value == "conflicting" then .generations.conflict = ((.generations.conflict // 0) + 1) | .events.conflict = {id: ("conflict:" + (.generations.conflict | tostring)), status: "pending", value: $value, detected_at: $now, lease: null} else . end) end' --arg value "$VALUE" --arg now "$NOW"
                ;;
            copilot)
                [[ "$VALUE" == "detected" || "$VALUE" == "none" ]] || { echo "Error: Invalid Copilot value" >&2; exit 1; }
                write_state 'if .observed.copilot == $value then . else .observed.copilot = $value | (if $value == "detected" then .generations.copilot_review = ((.generations.copilot_review // 0) + 1) | .events.copilot_review = {id: ("copilot_review:" + (.generations.copilot_review | tostring)), status: "pending", value: $value, detected_at: $now, lease: null} else . end) end' --arg value "$VALUE" --arg now "$NOW"
                ;;
            *) usage ;;
        esac
        ;;
    claim)
        verify_state
        [[ "$LEASE_ID" =~ ^[A-Za-z0-9_.-]+$ && "$LEASE_SECONDS" =~ ^[0-9]+$ ]] || usage
        PATH_EXPR=$(event_path)
        NOW_EPOCH=$(date +%s)
        EXPIRES_AT=$((NOW_EPOCH + LEASE_SECONDS))
        acquire_lock
        verify_state
        if ! jq -e --argjson now "$NOW_EPOCH" "$PATH_EXPR.status == \"pending\" and ($PATH_EXPR.lease == null or $PATH_EXPR.lease.expires_at_epoch <= \$now)" "$STATE_FILE" >/dev/null; then
            exit 3
        fi
        # event_path は固定の列挙値だけから作るため jq filter に安全に埋め込める。
        write_state "$PATH_EXPR.lease = {id: \"$LEASE_ID\", expires_at_epoch: $EXPIRES_AT}"
        ;;
    renew)
        verify_state
        [[ "$LEASE_ID" =~ ^[A-Za-z0-9_.-]+$ && "$LEASE_SECONDS" =~ ^[1-9][0-9]*$ ]] || usage
        PATH_EXPR=$(event_path)
        NOW_EPOCH=$(date +%s)
        EXPIRES_AT=$((NOW_EPOCH + LEASE_SECONDS))
        acquire_lock
        verify_state
        if ! jq -e --arg lease "$LEASE_ID" "$PATH_EXPR.status == \"pending\" and $PATH_EXPR.lease.id == \$lease" "$STATE_FILE" >/dev/null; then
            exit 3
        fi
        write_state "$PATH_EXPR.lease.expires_at_epoch = $EXPIRES_AT"
        ;;
    ack|release)
        verify_state
        [[ "$LEASE_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || usage
        PATH_EXPR=$(event_path)
        acquire_lock
        verify_state
        if ! jq -e --arg lease "$LEASE_ID" "$PATH_EXPR.lease.id == \$lease" "$STATE_FILE" >/dev/null; then
            exit 3
        fi
        if [[ "$COMMAND" == "ack" ]]; then
            write_state "$PATH_EXPR.status = \"acknowledged\" | $PATH_EXPR.lease = null | if .events.close != null and (.events.close.actions | all(.status != \"pending\")) then .events.close.status = \"acknowledged\" else . end"
        else
            write_state "$PATH_EXPR.lease = null"
        fi
        ;;
    watcher)
        verify_state
        [[ "$WATCHER_PID" =~ ^[0-9]+$ || "$WATCHER_PID" == "none" ]] || usage
        acquire_lock
        verify_state
        write_state '.watcher.pid = (if $pid == "none" then null else ($pid | tonumber) end) | .watcher.updated_at = $now | if $pid == "none" then . else .watcher.last_error = null end' --arg pid "$WATCHER_PID" --arg now "$(date -Iseconds)"
        ;;
    watcher-error)
        verify_state
        [[ "$WATCHER_REASON" == "initialization_failed" || "$WATCHER_REASON" == "foreground_required" ]] || usage
        acquire_lock
        verify_state
        write_state '.watcher.pid = null | .watcher.last_error = $reason | .watcher.updated_at = $now' --arg reason "$WATCHER_REASON" --arg now "$(date -Iseconds)"
        ;;
    api-failure)
        verify_state
        [[ "$FAILURE_COUNT" =~ ^[0-9]+$ ]] || usage
        acquire_lock
        verify_state
        write_state '.watcher.failures = ($count | tonumber) | .watcher.updated_at = $now' --arg count "$FAILURE_COUNT" --arg now "$(date -Iseconds)"
        ;;
    register-pane)
        verify_state
        [[ "$TMUX_PANE" =~ ^%[0-9]+$ && "$REGISTRATION_NONCE" =~ ^[A-Za-z0-9_.-]{16,}$ ]] || usage
        acquire_lock
        write_state '.version = 3 | .runtime = {pane: $pane, nonce: $nonce, session_id: null, status: "busy", updated_at: $now}' --arg pane "$TMUX_PANE" --arg nonce "$REGISTRATION_NONCE" --arg now "$(date -Iseconds)"
        ;;
    pane-status)
        verify_state
        [[ "$REGISTRATION_NONCE" =~ ^[A-Za-z0-9_.-]{16,}$ && "$SESSION_ID" =~ ^[A-Za-z0-9_.-]+$ && "$PANE_STATUS" =~ ^(busy|ready|approval_pending|stopped)$ ]] || usage
        acquire_lock
        if ! jq -e --arg nonce "$REGISTRATION_NONCE" '.runtime.nonce == $nonce' "$STATE_FILE" >/dev/null; then
            exit 3
        fi
        write_state '.version = 3 | .runtime.session_id = $session | .runtime.status = $status | .runtime.updated_at = $now' --arg session "$SESSION_ID" --arg status "$PANE_STATUS" --arg now "$(date -Iseconds)"
        ;;
    unregister-pane)
        verify_state
        [[ "$REGISTRATION_NONCE" =~ ^[A-Za-z0-9_.-]{16,}$ ]] || usage
        acquire_lock
        if ! jq -e --arg nonce "$REGISTRATION_NONCE" '.runtime.nonce == $nonce' "$STATE_FILE" >/dev/null; then
            exit 3
        fi
        write_state '.runtime = {pane: null, nonce: null, session_id: null, status: "stopped", updated_at: $now}' --arg now "$(date -Iseconds)"
        ;;
esac
