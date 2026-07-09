# tmuxセッション選択UI（10-tmux-selector）のcwd表示を最新に保つため、
# プロンプト表示のたびにTMUX_PROJECT_DIRをカレントディレクトリで更新する。
# tmux外では何もしない。
_update_tmux_project_dir() {
  [[ -n "${TMUX:-}" ]] || return 0
  tmux set-environment TMUX_PROJECT_DIR "$PWD" 2>/dev/null
}

# add-zsh-hookを用いてprecmdフックにidempotentに登録する
autoload -Uz add-zsh-hook
add-zsh-hook precmd _update_tmux_project_dir
