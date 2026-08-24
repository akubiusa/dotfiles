#!/bin/bash

set -euo pipefail

MAX_PARENT_HOPS=64
PANE_FORMAT="#{session_id}"$'\t'"#{window_id}"$'\t'"#{pane_id}"$'\t'"#{pane_pid}"

pane_info() {
    tmux display-message -p -t "$1" -F "$PANE_FORMAT"
}

valid_pane_info() {
    local info="$1" session_id window_id pane_id pane_pid extra

    [[ "$info" != *$'\n'* ]] || return 1
    IFS=$'\t' read -r session_id window_id pane_id pane_pid extra <<<"$info"
    [[ -n "$session_id" && "$window_id" =~ ^@[0-9]+$ && "$pane_id" =~ ^%[0-9]+$ && "$pane_pid" =~ ^[1-9][0-9]*$ && -z "$extra" ]]
}

pane_id_from_info() {
    local info="$1" _session_id _window_id pane_id _pane_pid

    IFS=$'\t' read -r _session_id _window_id pane_id _pane_pid <<<"$info"
    printf '%s\n' "$pane_id"
}

pane_pid_from_info() {
    local info="$1" _session_id _window_id _pane_id pane_pid

    IFS=$'\t' read -r _session_id _window_id _pane_id pane_pid <<<"$info"
    printf '%s\n' "$pane_pid"
}

direct_pane_info=""
if [[ "${TMUX_PANE:-}" =~ ^%[0-9]+$ ]]; then
    direct_pane_info=$(pane_info "$TMUX_PANE" 2>/dev/null || true)
    if valid_pane_info "$direct_pane_info" && [[ "$(pane_id_from_info "$direct_pane_info")" == "$TMUX_PANE" ]]; then
        printf '%s\n' "$TMUX_PANE"
        exit 0
    fi
fi

declare -A ancestor_pids=()
current_pid="$$"
for ((hop = 0; hop < MAX_PARENT_HOPS; hop++)); do
    [[ "$current_pid" =~ ^[1-9][0-9]*$ ]] || exit 1
    [[ -z "${ancestor_pids[$current_pid]:-}" ]] || exit 1
    ancestor_pids["$current_pid"]=1

    if parent_pid=$(ps -o ppid= -p "$current_pid" | tr -d '[:space:]'); then
        :
    else
        echo "Error: Unable to inspect the tmux process tree." >&2
        exit 1
    fi
    [[ "$parent_pid" =~ ^[1-9][0-9]*$ ]] || exit 1
    [[ "$parent_pid" != "$current_pid" ]] || exit 1
    [[ "$parent_pid" != "1" ]] || break
    current_pid="$parent_pid"
done

candidate_info=""
candidate_count=0
if ! pane_list=$(tmux list-panes -a -F "$PANE_FORMAT"); then
    echo "Error: Unable to list tmux panes." >&2
    exit 1
fi
while IFS= read -r info; do
    valid_pane_info "$info" || exit 1
    pane_pid=$(pane_pid_from_info "$info")
    [[ -n "${ancestor_pids[$pane_pid]:-}" ]] || continue
    candidate_count=$((candidate_count + 1))
    candidate_info="$info"
done <<<"$pane_list"

[[ "$candidate_count" -eq 1 ]] || exit 1
candidate_pane=$(pane_id_from_info "$candidate_info")
if revalidated_info=$(pane_info "$candidate_pane"); then
    :
else
    echo "Error: Unable to validate tmux pane." >&2
    exit 1
fi
valid_pane_info "$revalidated_info" || exit 1
[[ "$revalidated_info" == "$candidate_info" ]] || exit 1

printf '%s\n' "$candidate_pane"
