#!/bin/bash
# claudectl と claude-workctl の profile 分離を実行可能な fake CLI で検証する。
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PERSONAL_CTL="$ROOT_DIR/home/bin/executable_claudectl"
WORK_CTL="$ROOT_DIR/home/bin/executable_claude-workctl"
TEST_DIR=$(mktemp -d)
TEST_HOME="$TEST_DIR/home"
TEST_BIN="$TEST_DIR/bin"
TEST_WORKTREE="$TEST_DIR/worktree"
export TEST_DIR

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

[[ -f "$PERSONAL_CTL" ]] || {
    echo "❌ claudectl command is missing"
    exit 1
}
[[ -f "$WORK_CTL" ]] || {
    echo "❌ claude-workctl command is missing"
    exit 1
}

mkdir -p "$TEST_HOME" "$TEST_BIN" "$TEST_WORKTREE"
export HOME="$TEST_HOME"
export XDG_STATE_HOME="$TEST_DIR/state"
export PATH="$TEST_BIN:/usr/bin:/bin"
export CLAUDE_LOG="$TEST_DIR/claude.log"
export TMUX_LOG="$TEST_DIR/tmux.log"
export GIT_LOG="$TEST_DIR/git.log"

cat > "$TEST_BIN/claude" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'config=%s args=%s\n' "${CLAUDE_CONFIG_DIR-}" "$*" >> "$CLAUDE_LOG"
if [[ "$*" == "agents --json" ]]; then
    if [[ -f "$TEST_DIR/interrupted" ]]; then
        printf '%s\n' "$CLAUDE_AGENTS_AFTER_INTERRUPT"
    else
        printf '%s\n' "$CLAUDE_AGENTS_JSON"
    fi
fi
EOF
chmod +x "$TEST_BIN/claude"

cat > "$TEST_BIN/tmux" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
    new-session)
        [[ "${TMUX_NEW_SESSION_FAIL:-0}" != '1' ]]
        ;;
    send-keys)
        if [[ "$*" == *' -l -X' ]]; then
            exit 1
        fi
        if [[ "$*" == *' C-c' ]]; then
            : > "$TEST_DIR/interrupted"
        fi
        exit 0
        ;;
    attach-session|kill-session)
        exit 0
        ;;
    has-session)
        [[ "${TMUX_SESSION_EXISTS:-0}" == '1' ]]
        ;;
    list-panes)
        if [[ "$*" == *'#{pane_id}'* ]]; then
            printf '%%42\n'
        elif [[ "$*" == *' -t %42 '* ]]; then
            printf '4242\n'
        else
            printf '9999\n'
        fi
        ;;
    capture-pane)
        capture_count_file="$TEST_DIR/capture-count"
        capture_count=$(cat "$capture_count_file" 2> /dev/null || printf '0')
        capture_count=$((capture_count + 1))
        printf '%s\n' "$capture_count" > "$capture_count_file"
        if [[ "$capture_count" -eq 1 ]]; then
            printf '%s\n' "${TMUX_CAPTURE_BEFORE:-}"
        elif [[ "$capture_count" -le "${TMUX_CAPTURE_DELAY:-1}" ]]; then
            printf '\n'
        else
            printf '%s\n' "${TMUX_CAPTURE_AFTER:-}"
        fi
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$TEST_BIN/tmux"

cat > "$TEST_BIN/git" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$GIT_LOG"
case "$1 ${2:-}" in
    "rev-parse --is-inside-work-tree")
        printf 'true\n'
        ;;
    "rev-parse --show-toplevel")
        pwd
        ;;
    "status --porcelain")
        printf '%s\n' "${GIT_STATUS_OUTPUT:-}"
        exit 0
        ;;
    "symbolic-ref --quiet")
        printf 'origin/unrelated\n'
        ;;
    "branch --show-current")
        printf '%s\n' "${LOCAL_BASE:-local-main}"
        ;;
    "worktree add")
        mkdir -p "${@: -2:1}"
        ;;
    "merge-base --is-ancestor")
        [[ "${GIT_BRANCH_MERGED:-0}" == '1' ]]
        ;;
    "worktree remove")
        rmdir "${@: -1}"
        ;;
    "branch -d")
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$TEST_BIN/git"

write_state() {
    local profile="$1"
    local state_root="$XDG_STATE_HOME/$profile"
    local worktree="$state_root/worktrees/project"
    mkdir -p "$worktree" "$state_root/sessions/project"
    cat > "$state_root/sessions/project/session.json" <<EOF
{
  "profile": "$profile",
  "repository": "$TEST_DIR/repository",
  "worktree": "$worktree",
  "tmux_session": "$profile-project",
  "tmux_pane": "%42",
  "branch": "$profile/project",
  "base": "master"
}
EOF
}

write_state claudectl
write_state claude-workctl
export CLAUDE_AGENTS_JSON="[{\"cwd\":\"$XDG_STATE_HOME/claudectl/worktrees/project\",\"pid\":4242,\"status\":\"busy\"},{\"cwd\":\"$XDG_STATE_HOME/claude-workctl/worktrees/project\",\"pid\":4242,\"status\":\"busy\"}]"

personal_output=$(bash "$PERSONAL_CTL" status project)
work_output=$(bash "$WORK_CTL" status project)

grep -Fq 'busy' <<< "$personal_output" || {
    echo "❌ claudectl did not report its matching busy session"
    exit 1
}
grep -Fq 'busy' <<< "$work_output" || {
    echo "❌ claude-workctl did not report its matching busy session"
    exit 1
}
grep -Fxq 'config= args=agents --json' "$CLAUDE_LOG" || {
    echo "❌ claudectl did not use the default Claude profile"
    cat "$CLAUDE_LOG"
    exit 1
}
grep -Fxq "config=$TEST_HOME/.claude-work args=agents --json" "$CLAUDE_LOG" || {
    echo "❌ claude-workctl did not use its work Claude profile"
    cat "$CLAUDE_LOG"
    exit 1
}

export CLAUDE_AGENTS_JSON="[{\"cwd\":\"$TEST_DIR/unmanaged\",\"pid\":4242,\"status\":\"busy\"}]"
if bash "$PERSONAL_CTL" status project > /dev/null 2>&1; then
    echo "❌ claudectl associated an unrelated Claude session by PID alone"
    exit 1
fi

echo "✅ profile-specific status queries are isolated"

TEST_REPO="$TEST_DIR/repository"
mkdir -p "$TEST_REPO/.git"
rm -rf "$XDG_STATE_HOME/claudectl/sessions" "$XDG_STATE_HOME/claude-workctl/sessions"
rm -rf "$XDG_STATE_HOME/claudectl/worktrees" "$XDG_STATE_HOME/claude-workctl/worktrees"
: > "$TMUX_LOG"
: > "$GIT_LOG"

export TMUX_NEW_SESSION_FAIL=1
if (
    cd "$TEST_REPO"
    bash "$PERSONAL_CTL" start failed-launch
); then
    echo "❌ start succeeded when tmux could not launch Claude"
    exit 1
fi
[[ ! -e "$XDG_STATE_HOME/claudectl/worktrees/failed-launch" ]] || {
    echo "❌ start left a worktree behind after tmux launch failed"
    exit 1
}
grep -Fq 'branch -d claudectl/failed-launch' "$GIT_LOG" || {
    echo "❌ start did not safely roll back the failed branch"
    exit 1
}
unset TMUX_NEW_SESSION_FAIL

(
    cd "$TEST_REPO"
    bash "$PERSONAL_CTL" start project
)
(
    cd "$TEST_REPO"
    bash "$WORK_CTL" start project
)
(
    cd "$TEST_REPO"
    bash "$PERSONAL_CTL" start second
)

personal_state="$XDG_STATE_HOME/claudectl/sessions/project/session.json"
work_state="$XDG_STATE_HOME/claude-workctl/sessions/project/session.json"
[[ "$(jq -r '.worktree' "$personal_state")" == "$XDG_STATE_HOME/claudectl/worktrees/project" ]] || {
    echo "❌ claudectl did not use its isolated worktree root"
    exit 1
}
[[ "$(jq -r '.branch' "$personal_state")" == 'claudectl/project' ]] || {
    echo "❌ claudectl did not use its branch prefix"
    exit 1
}
[[ "$(jq -r '.tmux_session' "$personal_state")" == 'claudectl-project' ]] || {
    echo "❌ claudectl did not use its tmux prefix"
    exit 1
}
[[ "$(jq -r '.worktree' "$work_state")" == "$XDG_STATE_HOME/claude-workctl/worktrees/project" ]] || {
    echo "❌ claude-workctl did not use its isolated worktree root"
    exit 1
}
[[ "$(jq -r '.branch' "$work_state")" == 'claude-workctl/project' ]] || {
    echo "❌ claude-workctl did not use its branch prefix"
    exit 1
}
[[ "$(jq -r '.tmux_session' "$work_state")" == 'claude-workctl-project' ]] || {
    echo "❌ claude-workctl did not use its tmux prefix"
    exit 1
}
[[ -f "$XDG_STATE_HOME/claudectl/sessions/second/session.json" ]] || {
    echo "❌ claudectl did not retain a second named session"
    exit 1
}
[[ "$(jq -r '.base' "$personal_state")" == 'local-main' ]] || {
    echo "❌ start did not store the current local base branch"
    exit 1
}
! grep -Fq 'symbolic-ref' "$GIT_LOG" || {
    echo "❌ start consulted origin/HEAD instead of the local base branch"
    exit 1
}
grep -Fq -- '--permission-mode auto' "$TMUX_LOG" || {
    echo "❌ start did not launch Claude with the local auto permission mode"
    exit 1
}
grep -Fq -- '--append-system-prompt Never run git push or git merge.' "$TMUX_LOG" || {
    echo "❌ start did not guard Claude against push and merge"
    exit 1
}
grep -Fq -- "--settings $XDG_STATE_HOME/claudectl/sessions/project/claude-settings.json" "$TMUX_LOG" || {
    echo "❌ managed launch did not register its private hook settings"
    exit 1
}
grep -Fq -- '--disallowed-tools Bash(git push *) Bash(git merge *) Bash(gh pr merge *)' "$TMUX_LOG" || {
    echo "❌ managed launch did not add direct Git merge and push disallow rules"
    exit 1
}
! grep -Eq -- '(^| )--worktree($| )|(^| )--bg($| )|(^| )-p($| )' "$TMUX_LOG" || {
    echo "❌ start used a prohibited Claude execution mode"
    cat "$TMUX_LOG"
    exit 1
}
[[ "$(stat -c '%a' "$personal_state")" == '600' ]] || {
    echo "❌ state was not written with restrictive permissions"
    exit 1
}
[[ "$(stat -c '%a' "$XDG_STATE_HOME/claudectl")" == '700' ]] || {
    echo "❌ state root was not written with restrictive permissions"
    exit 1
}

jq --arg worktree "$TEST_DIR/unmanaged" '.worktree = $worktree' "$work_state" > "$work_state.tmp"
mv "$work_state.tmp" "$work_state"
if bash "$WORK_CTL" logs project > /dev/null 2>&1; then
    echo "❌ claude-workctl accepted state outside its managed worktree root"
    exit 1
fi

echo "✅ starts isolated profile-specific worktrees with guarded interactive Claude"

: > "$TMUX_LOG"
rm -f "$TEST_DIR/capture-count"
export CLAUDE_AGENTS_JSON="[{\"cwd\":\"$XDG_STATE_HOME/claudectl/worktrees/project\",\"pid\":4242,\"status\":\"busy\"}]"
export TMUX_CAPTURE_BEFORE='Review the pending change'
export TMUX_CAPTURE_AFTER='Press up to edit queued messages'
export TMUX_CAPTURE_DELAY=3

bash "$PERSONAL_CTL" prompt project 'Review the pending change'

mapfile -t prompt_sends < <(grep '^send-keys' "$TMUX_LOG")
[[ "${prompt_sends[0]:-}" == 'send-keys -t %42 -l -- Review the pending change' ]] || {
    echo "❌ prompt did not send literal text before submission"
    cat "$TMUX_LOG"
    exit 1
}
[[ "${prompt_sends[1]:-}" == 'send-keys -t %42 Enter' ]] || {
    echo "❌ prompt did not send Enter separately after literal text"
    cat "$TMUX_LOG"
    exit 1
}
[[ "${#prompt_sends[@]}" -eq 2 ]] || {
    echo "❌ prompt used more than the required literal-text and Enter operations"
    cat "$TMUX_LOG"
    exit 1
}
! grep -Eq '(^| )(Escape|Esc|C-c|C-C)($| )' "$TMUX_LOG" || {
    echo "❌ normal prompt interrupted Claude instead of queueing naturally"
    cat "$TMUX_LOG"
    exit 1
}
[[ "$(cat "$TEST_DIR/capture-count")" -ge 4 ]] || {
    echo "❌ prompt did not poll for queued-message acknowledgement"
    exit 1
}
grep -Fq 'capture-pane -p -J -t %42 -S -200' "$TMUX_LOG" || {
    echo "❌ prompt did not join wrapped TUI lines before verifying typed text"
    cat "$TMUX_LOG"
    exit 1
}

echo "✅ prompt queues literal text with a separate Enter and no interrupt"

: > "$TMUX_LOG"
rm -f "$TEST_DIR/capture-count"
export TMUX_CAPTURE_BEFORE='-X'
export TMUX_CAPTURE_AFTER='Press up to edit queued messages'

bash "$PERSONAL_CTL" prompt project '-X'

grep -Fxq 'send-keys -t %42 -l -- -X' "$TMUX_LOG" || {
    echo "❌ prompt treated option-like text as a tmux option instead of literal input"
    cat "$TMUX_LOG"
    exit 1
}

echo "✅ prompt preserves option-like text as literal input"

: > "$TMUX_LOG"
rm -f "$TEST_DIR/capture-count" "$TEST_DIR/interrupted"
export TMUX_CAPTURE_BEFORE='Claude transcript line'
export TMUX_CAPTURE_AFTER='Claude transcript line'
export CLAUDE_AGENTS_JSON="[{\"cwd\":\"$XDG_STATE_HOME/claudectl/worktrees/project\",\"pid\":4242,\"status\":\"busy\"}]"
export CLAUDE_AGENTS_AFTER_INTERRUPT="[{\"cwd\":\"$XDG_STATE_HOME/claudectl/worktrees/project\",\"pid\":4242,\"status\":\"idle\"}]"

logs_output=$(bash "$PERSONAL_CTL" logs project)
[[ "$logs_output" == *'Claude transcript line'* ]] || {
    echo "❌ logs did not capture the managed Claude TUI"
    exit 1
}
bash "$PERSONAL_CTL" attach project
bash "$PERSONAL_CTL" interrupt project
grep -Fq 'attach-session -t claudectl-project' "$TMUX_LOG" || {
    echo "❌ attach did not target the managed tmux session"
    exit 1
}
grep -Fq 'send-keys -t %42 C-c' "$TMUX_LOG" || {
    echo "❌ interrupt did not send an explicit interrupt to the managed pane"
    cat "$TMUX_LOG"
    exit 1
}

: > "$GIT_LOG"
rm -f "$TEST_DIR/interrupted"
export TMUX_SESSION_EXISTS=0
export CLAUDE_AGENTS_JSON="[{\"cwd\":\"$XDG_STATE_HOME/claudectl/worktrees/project\",\"pid\":4242,\"status\":\"idle\"}]"
export GIT_STATUS_OUTPUT=''
export GIT_BRANCH_MERGED=1
if bash "$PERSONAL_CTL" cleanup project > /dev/null 2>&1; then
    echo "❌ cleanup ran when it could not confirm the managed tmux session"
    exit 1
fi
[[ -f "$personal_state" ]] || {
    echo "❌ cleanup discarded state after failing to confirm its managed session"
    exit 1
}
! grep -Fq 'worktree remove' "$GIT_LOG" || {
    echo "❌ cleanup removed a worktree without confirming its managed session"
    exit 1
}

export TMUX_SESSION_EXISTS=1
export TMUX_SESSION_EXISTS=1
export CLAUDE_AGENTS_JSON="[{\"cwd\":\"$XDG_STATE_HOME/claudectl/worktrees/project\",\"pid\":4242,\"status\":\"busy\"}]"
if bash "$PERSONAL_CTL" cleanup project > /dev/null 2>&1; then
    echo "❌ cleanup ran while the managed Claude session was busy"
    exit 1
fi
! grep -Fq 'worktree remove' "$GIT_LOG" || {
    echo "❌ cleanup removed a worktree while Claude was busy"
    exit 1
}

export CLAUDE_AGENTS_JSON="[{\"cwd\":\"$XDG_STATE_HOME/claudectl/worktrees/project\",\"pid\":4242,\"status\":\"idle\"}]"
export GIT_STATUS_OUTPUT=' M uncommitted.txt'
if bash "$PERSONAL_CTL" cleanup project > /dev/null 2>&1; then
    echo "❌ cleanup ran with uncommitted work"
    exit 1
fi
! grep -Fq 'worktree remove' "$GIT_LOG" || {
    echo "❌ cleanup removed a dirty worktree"
    exit 1
}

export GIT_STATUS_OUTPUT=''
export GIT_BRANCH_MERGED=0
if bash "$PERSONAL_CTL" cleanup project > /dev/null 2>&1; then
    echo "❌ cleanup deleted an unmerged branch"
    exit 1
fi
! grep -Fq 'worktree remove' "$GIT_LOG" || {
    echo "❌ cleanup removed an unmerged branch worktree"
    exit 1
}

export GIT_BRANCH_MERGED=1
bash "$PERSONAL_CTL" cleanup project
[[ ! -e "$personal_state" ]] || {
    echo "❌ cleanup did not remove state after all guards passed"
    exit 1
}
grep -Fq 'worktree remove' "$GIT_LOG" || {
    echo "❌ cleanup did not remove the verified worktree"
    exit 1
}
grep -Fq 'branch -d claudectl/project' "$GIT_LOG" || {
    echo "❌ cleanup did not safely delete the merged branch"
    exit 1
}
! grep -Fq 'branch -D' "$GIT_LOG" || {
    echo "❌ cleanup force-deleted a branch"
    exit 1
}

echo "✅ logs, attach, interrupt, and cleanup safety guards work"
