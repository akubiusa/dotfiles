# tmuxセッション選択UI（10-tmux-selector）のcwd表示を最新に保つため、
# プロンプト表示のたびにTMUX_PROJECT_DIRをカレントディレクトリで更新する。
# tmux外では何もしない。
__bashrc_update_tmux_project_dir() {
  [[ -n "${TMUX:-}" ]] || return 0
  tmux set-environment TMUX_PROJECT_DIR "$PWD" 2>/dev/null
}

# PROMPT_COMMANDへの登録はidempotentに行う
if [[ "${PROMPT_COMMAND:-}" != *"__bashrc_update_tmux_project_dir"* ]]; then
  PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND}; }__bashrc_update_tmux_project_dir"
fi
