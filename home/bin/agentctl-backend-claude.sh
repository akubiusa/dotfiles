#!/bin/bash
# Claude backend (claude/claude-work) の exec command 構築ライブラリ。
# profile isolation (claude-work は CLAUDE_CONFIG_DIR を分離) と、
# session-local PreToolUse guard (agentctl-policy-dispatcher.sh) の配線を担う。
# 実 Claude CLI の起動確認は backend library ではなく live E2E で行う。

# session-local settings JSON を runtime dir に書き、guard hook を配線する。
# guard 本体は home/bin/agentctl-policy-dispatcher.sh を直接 source する薄い
# wrapper をここで生成する (Codex 側の
# home/dot_codex/hooks/executable_agentctl-policy-dispatcher.sh と同じ構造)。
# 成功時: 生成した settings JSON path を stdout に返す。失敗時は非 0 で return
# し、preflight 失敗として backend 起動全体を fail closed にする。
agentctl_backend_claude_write_guard_settings() {
  local dir="$1" guard_script settings_path
  guard_script="$dir/claude-guard-dispatcher.sh"
  settings_path="$dir/claude-session-settings.json"

  cat >"$guard_script" <<EOS
#!/bin/bash
# shellcheck disable=SC1091
source "$AGENTCTL_LIBDIR/agentctl-classify.sh"
source "$AGENTCTL_LIBDIR/agentctl-policy-dispatcher.sh"
agentctl_policy_dispatcher_main
EOS
  chmod 0700 "$guard_script"

  jq -n --arg cmd "bash $guard_script" '
    {hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $cmd, timeout: 10}]}]}}' \
    | agentctl_atomic_write "$settings_path" 0600

  # guard が確実に load される保証はここでは Claude 側の設定読み込みを実行できない
  # (この関数はまだ Claude process を起動していない) ため取れない。fail closed の
  # 保証は起動後 dispatcher 自身の fail-closed 挙動 (jq/snapshot 欠落時 deny) に委ねる。
  echo "$settings_path"
}

# 使い方: agentctl_backend_claude_command <backend> <policy_snapshot_path> <runtime_dir>
# 標準出力: `bash -c` に渡す exec command string。
agentctl_backend_claude_command() {
  local backend="$1" policy_snapshot_path="$2" dir="$3"
  local settings_path config_dir_env="" permission_mode_flag=""
  settings_path=$(agentctl_backend_claude_write_guard_settings "$dir") || return 1

  if [ "$backend" = "claude-work" ]; then
    config_dir_env="CLAUDE_CONFIG_DIR=\"\$HOME/.claude-work\" "
  fi

  # local_write=false は Claude の Plan mode (--permission-mode plan) で強制する。
  # Plan mode は Edit/Write/Bash 等の filesystem mutation tool を機械的に禁止する
  # filesystem mutation tool を機械的に禁止する read-only mode として使う。
  local local_write
  local_write=$(jq -r '.permissions.local_write' "$policy_snapshot_path")
  [ "$local_write" = "true" ] || permission_mode_flag=" --permission-mode plan"

  printf '%sexec claude --settings %q%s' "$config_dir_env" "$settings_path" "$permission_mode_flag"
}
