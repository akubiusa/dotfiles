# tmux セッション選択UI（10-tmux-selector）の cwd 表示を最新に保つため、
# プロンプト表示のたびに TMUX_PROJECT_DIR をカレントディレクトリで更新する。
# tmux 外では何もしない。
_update_tmux_project_dir() {
  [[ -n "${TMUX:-}" ]] || return 0
  tmux set-environment TMUX_PROJECT_DIR "$PWD" 2>/dev/null
}

# add-zsh-hook を用いて precmd フックに idempotent に登録する
autoload -Uz add-zsh-hook
add-zsh-hook precmd _update_tmux_project_dir
