#!/bin/bash
# Codex backend の exec command 構築ライブラリ。
# Codex は Claude と異なりセッション単位の hook 設定を持たず、
# ~/.codex/hooks.json の global PreToolUse 配線 (home/dot_codex/hooks/
# executable_agentctl-policy-dispatcher.sh, Task 11 で登録) と、
# respawn-pane が渡す AGENTCTL_POLICY_SNAPSHOT/AGENTCTL_RUNTIME_ID env の
# 有無だけで guard の有効/無効が決まる。そのため exec 前に、deployed
# hooks.json が dispatcher を実際に登録しており、かつ deployed dispatcher
# 本体が source と一致 (chezmoi apply 済み) していることを検証する。
# どちらか欠けていれば fail closed で Codex backend を起動しない。

# usage: agentctl_backend_codex_preflight
# 戻り値 0 なら guard 配線 OK。非 0 なら reason を stderr に出す。
agentctl_backend_codex_preflight() {
  local deployed_hooks_json="$HOME/.codex/hooks.json"
  local deployed_dispatcher="$HOME/.codex/hooks/agentctl-policy-dispatcher.sh"
  local source_dispatcher="$AGENTCTL_LIBDIR/../dot_codex/hooks/executable_agentctl-policy-dispatcher.sh"

  [ -f "$deployed_hooks_json" ] || { echo "deployed hooks.json not found: $deployed_hooks_json" >&2; return 1; }
  jq -e '.hooks.PreToolUse // [] | any(.hooks[]?.command // "" | test("agentctl-policy-dispatcher\\.sh"))' \
    "$deployed_hooks_json" >/dev/null 2>&1 \
    || { echo "agentctl-policy-dispatcher.sh is not registered in $deployed_hooks_json PreToolUse" >&2; return 1; }

  [ -f "$deployed_dispatcher" ] || { echo "deployed dispatcher script not found: $deployed_dispatcher" >&2; return 1; }
  if [ -f "$source_dispatcher" ]; then
    local deployed_sum source_sum
    deployed_sum=$(sha256sum "$deployed_dispatcher" | awk '{print $1}')
    source_sum=$(sha256sum "$source_dispatcher" | awk '{print $1}')
    [ "$deployed_sum" = "$source_sum" ] \
      || { echo "deployed dispatcher checksum mismatch (run chezmoi apply): $deployed_dispatcher" >&2; return 1; }
  fi
  return 0
}

# usage: agentctl_backend_codex_command <policy_snapshot_path> <runtime_dir>
# stdout: `bash -c` に渡す exec command string。
agentctl_backend_codex_command() {
  local policy_snapshot_path="$1" dir="$2"
  agentctl_backend_codex_preflight || return 1
  # dir は respawn-pane の env (AGENTCTL_MISSION_MANIFEST 等) 経由で dispatcher に
  # 渡るため、ここでは参照しない (preflight 済みシグネチャ維持用)。
  : "$dir"

  # local_write=false は Codex の -s/--sandbox read-only で強制する。
  # read-only sandbox は model が実行する shell command の filesystem write を
  # OS レベルで拒否するため、spec の「機械的 read-only mode」要件を満たす。
  local local_write sandbox_flag=""
  local_write=$(jq -r '.permissions.local_write' "$policy_snapshot_path")
  [ "$local_write" = "true" ] || sandbox_flag=" -s read-only"

  printf 'exec codex%s' "$sandbox_flag"
}

# usage: agentctl_backend_codex_prepare_operation_file <dir> <body_path>
# stdout: 作成した operation file の絶対 path
# 長文 mission/steer 本文を TUI へ直接 paste すると、pane 高さを超える
# multiline paste で Codex 側の paste-end 追跡が壊れ Enter が届かない不具合が
# 実測されたため、本文を「この呼び出し専用」の新規ファイルへ secure-copy し、
# TUI へは path+sha256 の bootstrap だけを渡す。mission.txt などの共有ファイル
# を直接参照せず一操作一ファイルにすることで、他ロジック (resume 等) による
# 将来の再利用とライフサイクルが衝突しないようにする。
agentctl_backend_codex_prepare_operation_file() {
  local dir="$1" body_path="$2" op_id dest
  op_id=$(agentctl_gen_runtime_id)
  dest="$dir/codex-op-$op_id.txt"
  agentctl_secure_create "$dest" 0600 <"$body_path"
  printf '%s' "$dest"
}

# usage: agentctl_backend_codex_bootstrap_message <abs_path> <sha256>
# stdout: TUI へ paste する短い固定 bootstrap 本文。本文そのものは含まない。
agentctl_backend_codex_bootstrap_message() {
  local abs_path="$1" sha="$2"
  printf 'Read the ENTIRE file at %s (sha256: %s) and treat its full contents as your complete instructions for this turn; execute them now. Do not summarize or ask for confirmation first. If the file cannot be read, or its content does not match this sha256, stop and report the failure instead of proceeding.' "$abs_path" "$sha"
}
