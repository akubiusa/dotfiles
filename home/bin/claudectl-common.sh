#!/bin/bash

set -euo pipefail

claudectl_state_root() {
    printf '%s/%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$1"
}

claudectl_normalize_rendered_text() {
    tr '\r\n\t' '   ' | sed -E 's/ +/ /g'
}

claudectl_count_literal_occurrences() {
    local haystack="$1"
    local needle="$2"
    local count=0

    [[ -n "$needle" ]] || {
        printf '0\n'
        return 0
    }
    while [[ "$haystack" == *"$needle"* ]]; do
        haystack=${haystack#*"$needle"}
        count=$((count + 1))
    done
    printf '%s\n' "$count"
}

claudectl_session_state() {
    local profile="$1"
    local name="$2"

    printf '%s/session.json\n' "$(claudectl_session_dir "$profile" "$name")"
}

claudectl_session_dir() {
    local profile="$1"
    local name="$2"

    claudectl_validate_name "$name"
    printf '%s/sessions/%s\n' "$(claudectl_state_root "$profile")" "$name"
}

claudectl_remove_session_dir() {
    local profile="$1"
    local name="$2"
    local state_root sessions_root session_dir

    state_root=$(claudectl_state_root "$profile")
    sessions_root="$state_root/sessions"
    session_dir=$(claudectl_session_dir "$profile" "$name")
    [[ "$session_dir" == "$sessions_root/"* && "${session_dir##*/}" == "$name" ]] || {
        printf 'Refusing to remove an invalid managed session directory.\n' >&2
        return 1
    }
    rm -rf -- "$session_dir"
}

claudectl_validate_state() {
    local profile="$1"
    local state="$2"
    local name="$3"
    local state_root expected_state stored_profile worktree branch tmux_session tmux_pane

    claudectl_validate_name "$name"
    state_root=$(claudectl_state_root "$profile")
    expected_state=$(claudectl_session_state "$profile" "$name")
    stored_profile=$(jq -er '.profile' "$state")
    worktree=$(jq -er '.worktree' "$state")
    branch=$(jq -er '.branch' "$state")
    tmux_session=$(jq -er '.tmux_session' "$state")
    tmux_pane=$(jq -er '.tmux_pane' "$state")

    [[ "$state" == "$expected_state" && "$stored_profile" == "$profile" && "$worktree" == "$state_root/worktrees/$name" ]] || {
        printf 'Managed state does not belong to %s.\n' "$profile" >&2
        return 1
    }
    [[ "$branch" == "$profile/$name" && "$tmux_session" == "$profile-$name" && "$tmux_pane" =~ ^%[0-9]+$ ]] || {
        printf 'Managed state has invalid resource identifiers.\n' >&2
        return 1
    }
}

claudectl_with_profile() {
    local profile="$1"
    shift

    if [[ "$profile" == "claudectl" ]]; then
        unset CLAUDE_CONFIG_DIR
    else
        export CLAUDE_CONFIG_DIR="$HOME/.claude-work"
    fi

    "$@"
}

claudectl_managed_agent() {
    local profile="$1"
    local worktree="$2"
    local pane_pid="$3"
    local agents matches

    agents=$(claudectl_with_profile "$profile" claude agents --json)
    matches=$(jq -ce --arg worktree "$worktree" --arg pid "$pane_pid" '
        [ .[]
          | select((.cwd // .workingDirectory // .worktree // "") == $worktree)
          | select((.pid // .processId // .process_id // -1 | tostring) == $pid)
        ]
    ' <<< "$agents")
    if [[ "$(jq 'length' <<< "$matches")" -ne 1 ]]; then
        printf 'Managed session was not uniquely matched by worktree and pane PID.\n' >&2
        return 1
    fi
    jq -c '.[0]' <<< "$matches"
}

claudectl_status() {
    local profile="$1"
    local name="$2"
    local state worktree tmux_session tmux_pane pane_pid agent status

    state=$(claudectl_session_state "$profile" "$name")
    [[ -f "$state" ]] || {
        printf '%s has no managed Claude session.\n' "$profile" >&2
        return 1
    }
    claudectl_validate_state "$profile" "$state" "$name"

    worktree=$(jq -er '.worktree' "$state")
    tmux_session=$(jq -er '.tmux_session' "$state")
    tmux_pane=$(jq -er '.tmux_pane' "$state")
    pane_pid=$(tmux list-panes -t "$tmux_pane" -F '#{pane_pid}')
    [[ "$pane_pid" =~ ^[0-9]+$ ]] || {
        printf '%s managed tmux session has no Claude pane.\n' "$profile" >&2
        return 1
    }

    agent=$(claudectl_managed_agent "$profile" "$worktree" "$pane_pid")
    status=$(jq -r '.status // .state // "active"' <<< "$agent")
    printf '%s %s %s\n' "$profile" "$tmux_session" "$status"
}

claudectl_validate_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
        printf 'Session name must contain only letters, numbers, dot, underscore, and hyphen.\n' >&2
        return 1
    }
}

claudectl_trust_worktree() {
    local profile="$1"
    local worktree="$2"
    local config tmp perm

    if [[ "$profile" == "claudectl" ]]; then
        config="$HOME/.claude.json"
    else
        config="$HOME/.claude-work/.claude.json"
    fi

    [[ -f "$config" ]] || return 0
    command -v jq > /dev/null 2>&1 || return 0
    if [[ "$(jq -r --arg p "$worktree" '.projects[$p].hasTrustDialogAccepted // false' "$config" 2> /dev/null)" == "true" ]]; then
        return 0
    fi

    tmp=$(mktemp "${config}.XXXXXX") || return 0
    perm=$(stat -c '%a' "$config" 2> /dev/null || stat -f '%Lp' "$config" 2> /dev/null)
    [[ -z "$perm" ]] || chmod "$perm" "$tmp"
    if jq --arg p "$worktree" '.projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})' "$config" > "$tmp"; then
        mv "$tmp" "$config"
    else
        rm -f "$tmp"
    fi
}

claudectl_untrust_worktree() {
    local profile="$1"
    local worktree="$2"
    local config tmp perm

    if [[ "$profile" == "claudectl" ]]; then
        config="$HOME/.claude.json"
    else
        config="$HOME/.claude-work/.claude.json"
    fi

    [[ -f "$config" ]] || return 0
    command -v jq > /dev/null 2>&1 || return 0
    [[ "$(jq -r --arg p "$worktree" '.projects[$p] // null' "$config" 2> /dev/null)" != "null" ]] || return 0

    tmp=$(mktemp "${config}.XXXXXX") || return 1
    perm=$(stat -c '%a' "$config" 2> /dev/null || stat -f '%Lp' "$config" 2> /dev/null)
    [[ -z "$perm" ]] || chmod "$perm" "$tmp"
    if jq --arg p "$worktree" 'del(.projects[$p])' "$config" > "$tmp"; then
        mv "$tmp" "$config"
    else
        rm -f "$tmp"
        return 1
    fi
}

claudectl_write_state() {
    local profile="$1"
    local repository="$2"
    local worktree="$3"
    local branch="$4"
    local base="$5"
    local tmux_session="$6"
    local tmux_pane="$7"
    local name="$8"
    local state_root state session_dir tmp

    state_root=$(claudectl_state_root "$profile")
    session_dir="$state_root/sessions/$name"
    state="$session_dir/session.json"
    umask 077
    mkdir -p "$session_dir"
    chmod 700 "$state_root"
    chmod 700 "$state_root/sessions" "$session_dir"
    tmp=$(mktemp "$state.XXXXXX") || return 1
    if ! jq -n \
        --arg profile "$profile" \
        --arg repository "$repository" \
        --arg worktree "$worktree" \
        --arg branch "$branch" \
        --arg base "$base" \
        --arg tmux_session "$tmux_session" \
        --arg tmux_pane "$tmux_pane" \
        '{profile: $profile, repository: $repository, worktree: $worktree, branch: $branch, base: $base, tmux_session: $tmux_session, tmux_pane: $tmux_pane}' > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! chmod 600 "$tmp" || ! mv "$tmp" "$state"; then
        rm -f "$tmp"
        return 1
    fi
}

claudectl_write_session_settings() {
    local profile="$1"
    local name="$2"
    local state_root session_dir settings tmp hook

    state_root=$(claudectl_state_root "$profile")
    session_dir="$state_root/sessions/$name"
    settings="$session_dir/claude-settings.json"
    hook="$HOME/.claude/hooks/claudectl-git-guard.sh"
    umask 077
    mkdir -p "$session_dir"
    chmod 700 "$state_root" "$state_root/sessions" "$session_dir"
    tmp=$(mktemp "$settings.XXXXXX") || return 1
    if ! jq -n --arg hook "$hook" '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $hook}]}]}}' > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! chmod 600 "$tmp" || ! mv "$tmp" "$settings"; then
        rm -f "$tmp"
        return 1
    fi
    printf '%s\n' "$settings"
}

claudectl_start() {
    local profile="$1"
    local name="$2"
    local state_root state repository base worktree branch tmux_session tmux_pane guard settings

    claudectl_validate_name "$name"
    state_root=$(claudectl_state_root "$profile")
    state=$(claudectl_session_state "$profile" "$name")
    [[ ! -e "$state" ]] || {
        printf '%s already has a managed Claude session. Run cleanup before starting another.\n' "$profile" >&2
        return 1
    }
    git rev-parse --is-inside-work-tree > /dev/null 2>&1 || {
        printf 'start must be run from a Git worktree.\n' >&2
        return 1
    }
    [[ -z "$(git status --porcelain)" ]] || {
        printf 'Refusing to create a managed worktree from a dirty repository.\n' >&2
        return 1
    }

    repository=$(git rev-parse --show-toplevel)
    base=$(git branch --show-current)
    [[ -n "$base" ]] || {
        printf 'Unable to determine the base branch.\n' >&2
        return 1
    }
    worktree="$state_root/worktrees/$name"
    branch="$profile/$name"
    tmux_session="$profile-$name"
    [[ ! -e "$worktree" ]] || {
        printf 'Managed worktree path already exists: %s\n' "$worktree" >&2
        return 1
    }
    if tmux has-session -t "$tmux_session" 2> /dev/null; then
        printf 'Managed tmux session name already exists: %s\n' "$tmux_session" >&2
        return 1
    fi
    git worktree add -b "$branch" "$worktree" "$base"

    claudectl_trust_worktree "$profile" "$worktree"
    settings=$(claudectl_write_session_settings "$profile" "$name") || {
        claudectl_untrust_worktree "$profile" "$worktree" || true
        (cd "$repository" && git worktree remove "$worktree") || true
        (cd "$repository" && git branch -d "$branch") || true
        claudectl_remove_session_dir "$profile" "$name" || true
        return 1
    }
    guard='Never run git push or git merge. The controller owns the Git worktree.'
    if [[ "$profile" == "claudectl" ]]; then
        if ! tmux new-session -d -s "$tmux_session" -c "$worktree" env -u CLAUDE_CONFIG_DIR claude --permission-mode auto --settings "$settings" --disallowed-tools 'Bash(git push *)' 'Bash(git merge *)' 'Bash(gh pr merge *)' --append-system-prompt "$guard"; then
            claudectl_untrust_worktree "$profile" "$worktree" || true
            (cd "$repository" && git worktree remove "$worktree") || true
            (cd "$repository" && git branch -d "$branch") || true
            claudectl_remove_session_dir "$profile" "$name" || true
            return 1
        fi
    else
        if ! tmux new-session -d -s "$tmux_session" -c "$worktree" env "CLAUDE_CONFIG_DIR=$HOME/.claude-work" claude --permission-mode auto --settings "$settings" --disallowed-tools 'Bash(git push *)' 'Bash(git merge *)' 'Bash(gh pr merge *)' --append-system-prompt "$guard"; then
            claudectl_untrust_worktree "$profile" "$worktree" || true
            (cd "$repository" && git worktree remove "$worktree") || true
            (cd "$repository" && git branch -d "$branch") || true
            claudectl_remove_session_dir "$profile" "$name" || true
            return 1
        fi
    fi
    tmux_pane=$(tmux list-panes -t "$tmux_session" -F '#{pane_id}' | head -n 1)
    [[ "$tmux_pane" =~ ^%[0-9]+$ ]] || {
        tmux kill-session -t "$tmux_session" 2> /dev/null || true
        claudectl_untrust_worktree "$profile" "$worktree" || true
        (cd "$repository" && git worktree remove "$worktree") || true
        (cd "$repository" && git branch -d "$branch") || true
        claudectl_remove_session_dir "$profile" "$name" || true
        printf 'Managed tmux session has no pane.\n' >&2
        return 1
    }
    if ! claudectl_write_state "$profile" "$repository" "$worktree" "$branch" "$base" "$tmux_session" "$tmux_pane" "$name"; then
        tmux kill-session -t "$tmux_session" 2> /dev/null || true
        claudectl_untrust_worktree "$profile" "$worktree" || true
        (cd "$repository" && git worktree remove "$worktree") || true
        (cd "$repository" && git branch -d "$branch") || true
        claudectl_remove_session_dir "$profile" "$name" || true
        return 1
    fi
    printf 'Started %s in %s.\n' "$tmux_session" "$worktree"
}

claudectl_prompt() {
    local profile="$1"
    local name="$2"
    local prompt="$3"
    local state worktree tmux_session tmux_pane pane_pid before_agent before_status baseline normalized_baseline baseline_count typed normalized_typed normalized_prompt rendered_count after after_agent after_status attempt

    state=$(claudectl_session_state "$profile" "$name")
    [[ -f "$state" ]] || {
        printf '%s has no managed Claude session.\n' "$profile" >&2
        return 1
    }
    claudectl_validate_state "$profile" "$state" "$name"
    worktree=$(jq -er '.worktree' "$state")
    tmux_session=$(jq -er '.tmux_session' "$state")
    tmux_pane=$(jq -er '.tmux_pane' "$state")
    tmux list-panes -t "$tmux_session" -F '#{pane_id}' | grep -Fxq "$tmux_pane" || {
        printf '%s managed tmux pane no longer exists.\n' "$profile" >&2
        return 1
    }
    pane_pid=$(tmux list-panes -t "$tmux_pane" -F '#{pane_pid}')
    [[ "$pane_pid" =~ ^[0-9]+$ ]] || {
        printf '%s managed tmux pane has no Claude process.\n' "$profile" >&2
        return 1
    }
    before_agent=$(claudectl_managed_agent "$profile" "$worktree" "$pane_pid")
    before_status=$(jq -r '.status // .state // "unknown"' <<< "$before_agent")

    normalized_prompt=$(printf '%s' "$prompt" | claudectl_normalize_rendered_text)
    baseline=$(tmux capture-pane -p -J -t "$tmux_pane" -S -200)
    normalized_baseline=$(printf '%s' "$baseline" | claudectl_normalize_rendered_text)
    baseline_count=$(claudectl_count_literal_occurrences "$normalized_baseline" "$normalized_prompt")
    tmux send-keys -t "$tmux_pane" -l -- "$prompt"
    for attempt in {1..5}; do
        typed=$(tmux capture-pane -p -J -t "$tmux_pane" -S -200)
        normalized_typed=$(printf '%s' "$typed" | claudectl_normalize_rendered_text)
        rendered_count=$(claudectl_count_literal_occurrences "$normalized_typed" "$normalized_prompt")
        [[ "$rendered_count" -gt "$baseline_count" ]] && break
        [[ "$attempt" -eq 5 ]] || sleep 0.1
    done
    [[ "$rendered_count" -gt "$baseline_count" ]] || {
        printf 'Claude did not show the literal prompt before submission.\n' >&2
        return 1
    }
    tmux send-keys -t "$tmux_pane" Enter
    for attempt in {1..5}; do
        after=$(tmux capture-pane -p -J -t "$tmux_pane" -S -200)
        after_agent=$(claudectl_managed_agent "$profile" "$worktree" "$pane_pid")
        after_status=$(jq -r '.status // .state // "unknown"' <<< "$after_agent")
        if grep -Fq 'Press up to edit queued messages' <<< "$after"; then
            printf 'Prompt accepted and queued.\n'
            return 0
        fi
        if [[ "$before_status" =~ ^(idle|waiting|ready)$ && "$after_status" =~ ^(busy|working|active)$ ]]; then
            printf 'Prompt accepted.\n'
            return 0
        fi
        [[ "$attempt" -eq 5 ]] || sleep 0.1
    done
    printf 'Claude did not acknowledge the submitted prompt.\n' >&2
    return 1
}

claudectl_logs() {
    local profile="$1"
    local name="$2"
    local state tmux_pane

    state=$(claudectl_session_state "$profile" "$name")
    [[ -f "$state" ]] || {
        printf '%s has no managed Claude session.\n' "$profile" >&2
        return 1
    }
    claudectl_validate_state "$profile" "$state" "$name"
    tmux_pane=$(jq -er '.tmux_pane' "$state")
    tmux capture-pane -p -J -t "$tmux_pane" -S -1000
}

claudectl_attach() {
    local profile="$1"
    local name="$2"
    local state tmux_session

    state=$(claudectl_session_state "$profile" "$name")
    [[ -f "$state" ]] || {
        printf '%s has no managed Claude session.\n' "$profile" >&2
        return 1
    }
    claudectl_validate_state "$profile" "$state" "$name"
    tmux_session=$(jq -er '.tmux_session' "$state")
    tmux attach-session -t "$tmux_session"
}

claudectl_interrupt() {
    local profile="$1"
    local name="$2"
    local state worktree tmux_session tmux_pane pane_pid before_agent before_status after_agent after_status

    state=$(claudectl_session_state "$profile" "$name")
    [[ -f "$state" ]] || {
        printf '%s has no managed Claude session.\n' "$profile" >&2
        return 1
    }
    claudectl_validate_state "$profile" "$state" "$name"
    worktree=$(jq -er '.worktree' "$state")
    tmux_session=$(jq -er '.tmux_session' "$state")
    tmux_pane=$(jq -er '.tmux_pane' "$state")
    pane_pid=$(tmux list-panes -t "$tmux_pane" -F '#{pane_pid}')
    [[ "$pane_pid" =~ ^[0-9]+$ ]] || {
        printf '%s managed tmux pane has no Claude process.\n' "$profile" >&2
        return 1
    }
    before_agent=$(claudectl_managed_agent "$profile" "$worktree" "$pane_pid")
    before_status=$(jq -r '.status // .state // "unknown"' <<< "$before_agent")
    [[ "$before_status" =~ ^(busy|working|active)$ ]] || {
        printf 'Managed Claude session is not busy.\n' >&2
        return 1
    }
    tmux send-keys -t "$tmux_pane" C-c
    tmux capture-pane -p -J -t "$tmux_pane" -S -200 > /dev/null
    after_agent=$(claudectl_managed_agent "$profile" "$worktree" "$pane_pid")
    after_status=$(jq -r '.status // .state // "unknown"' <<< "$after_agent")
    [[ ! "$after_status" =~ ^(busy|working|active)$ ]] || {
        printf 'Claude remained busy after interrupt.\n' >&2
        return 1
    }
    printf 'Claude interrupt acknowledged.\n'
}

claudectl_cleanup() {
    local profile="$1"
    local name="$2"
    local state repository worktree branch base tmux_session tmux_pane pane_pid agent status

    state=$(claudectl_session_state "$profile" "$name")
    [[ -f "$state" ]] || {
        printf '%s has no managed Claude session.\n' "$profile" >&2
        return 1
    }
    claudectl_validate_state "$profile" "$state" "$name"
    repository=$(jq -er '.repository' "$state")
    worktree=$(jq -er '.worktree' "$state")
    branch=$(jq -er '.branch' "$state")
    base=$(jq -er '.base' "$state")
    tmux_session=$(jq -er '.tmux_session' "$state")
    tmux_pane=$(jq -er '.tmux_pane' "$state")

    tmux has-session -t "$tmux_session" 2> /dev/null || {
        printf 'Unable to confirm the managed tmux session.\n' >&2
        return 1
    }
    pane_pid=$(tmux list-panes -t "$tmux_pane" -F '#{pane_pid}')
    [[ "$pane_pid" =~ ^[0-9]+$ ]] || {
        printf 'Unable to verify the managed Claude process.\n' >&2
        return 1
    }
    agent=$(claudectl_managed_agent "$profile" "$worktree" "$pane_pid")
    status=$(jq -r '.status // .state // "unknown"' <<< "$agent")
    [[ ! "$status" =~ ^(busy|working|active)$ ]] || {
        printf 'Refusing cleanup while the managed Claude session is %s.\n' "$status" >&2
        return 1
    }
    [[ -z "$(cd "$worktree" && git status --porcelain)" ]] || {
        printf 'Refusing cleanup because the managed worktree is dirty.\n' >&2
        return 1
    }
    (cd "$repository" && git merge-base --is-ancestor "$branch" "$base") || {
        printf 'Refusing cleanup because %s is not merged into %s.\n' "$branch" "$base" >&2
        return 1
    }
    claudectl_untrust_worktree "$profile" "$worktree" || {
        printf 'Refusing cleanup because the managed Claude trust entry could not be removed.\n' >&2
        return 1
    }

    tmux kill-session -t "$tmux_session" 2> /dev/null || true
    (cd "$repository" && git worktree remove "$worktree")
    (cd "$repository" && git branch -d "$branch")
    claudectl_remove_session_dir "$profile" "$name"
    printf 'Cleaned up %s.\n' "$tmux_session"
}

claudectl_main() {
    local profile="$1"
    local command_name="$2"
    shift 2

    case "${1:-}" in
        start)
            shift
            [[ "$#" -eq 1 ]] || {
                printf 'Usage: %s start <name>\n' "$command_name" >&2
                return 2
            }
            claudectl_start "$profile" "$1"
            ;;
        prompt)
            shift
            [[ "$#" -eq 2 && -n "$2" ]] || {
                printf 'Usage: %s prompt <name> <text>\n' "$command_name" >&2
                return 2
            }
            claudectl_prompt "$profile" "$1" "$2"
            ;;
        logs)
            shift
            [[ "$#" -eq 1 ]] || return 2
            claudectl_logs "$profile" "$1"
            ;;
        attach)
            shift
            [[ "$#" -eq 1 ]] || return 2
            claudectl_attach "$profile" "$1"
            ;;
        interrupt)
            shift
            [[ "$#" -eq 1 ]] || return 2
            claudectl_interrupt "$profile" "$1"
            ;;
        cleanup)
            shift
            [[ "$#" -eq 1 ]] || return 2
            claudectl_cleanup "$profile" "$1"
            ;;
        status)
            shift
            [[ "$#" -eq 1 ]] || {
                printf 'Usage: %s status <name>\n' "$command_name" >&2
                return 2
            }
            claudectl_status "$profile" "$1"
            ;;
        *)
            printf 'Usage: %s {start <name>|status}\n' "$command_name" >&2
            return 2
            ;;
    esac
}
