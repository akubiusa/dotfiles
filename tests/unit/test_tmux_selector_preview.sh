#!/bin/bash
# tmux セレクターが端末幅によらずプレビューを渡すことを検証する。

set -euo pipefail

SCRIPT="home/dot_bash_profile.d/executable_10-tmux-selector.sh"
if [[ ! -f "$SCRIPT" ]]; then
  echo "Script not found: $SCRIPT" >&2
  exit 1
fi

export TMUX_SELECTOR_DISABLE_AUTO=1
# shellcheck source=/dev/null
source "$SCRIPT"

tmux() {
  case "$1" in
    list-sessions) printf 'session1|0|1|1\n' ;;
    list-panes) printf '%%1 1\n' ;;
    display-message)
      if [[ "$*" == *pane_current_command* ]]; then
        printf 'bash\n'
      else
        printf '%s\n' "$HOME"
      fi
      ;;
    show-environment) return 0 ;;
    attach-session) return 0 ;;
    *) return 1 ;;
  esac
}

tput() {
  printf '40\n'
}

fzf() {
  local arg has_preview=0 has_preview_window=0
  for arg in "$@"; do
    [[ "$arg" == "--preview" ]] && has_preview=1
    [[ "$arg" == --preview-window=* ]] && has_preview_window=1
  done
  if (( !has_preview || !has_preview_window )); then
    echo "fzf did not receive both preview options" >&2
    return 1
  fi
  cat >/dev/null
  printf 'session1: [bash|1d] (~) 1w\tSESSION\tsession1\t%%1\n'
}

tmux_session_selector
echo "Narrow-terminal preview test passed"
