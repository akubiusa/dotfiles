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


AGENTCTL_CODEX_GUARD_DISPATCHER_SHA256="44135b02a7104fbf9f1aa60a72b3ca037bd993ef7a441c0abddcdab8157b688a"
AGENTCTL_CODEX_GUARD_MATCHER='^(Bash|exec)$'
AGENTCTL_CODEX_GUARD_COMMAND='bash ~/.codex/hooks/agentctl-policy-dispatcher.sh'

# usage: agentctl_backend_codex_preflight
# 戻り値 0 なら guard 配線 OK。非 0 なら reason を stderr に出す。
agentctl_backend_codex_preflight() {
  local deployed_hooks_json="$HOME/.codex/hooks.json"
  local deployed_dispatcher="$HOME/.codex/hooks/agentctl-policy-dispatcher.sh"

  command -v jq >/dev/null 2>&1 \
    || { echo "jq is required for Codex guard preflight" >&2; return 1; }
  command -v sha256sum >/dev/null 2>&1 \
    || { echo "sha256sum is required for Codex guard preflight" >&2; return 1; }
  [ -f "$deployed_hooks_json" ] \
    || { echo "deployed hooks.json not found: $deployed_hooks_json" >&2; return 1; }

  # hooks.json は unrelated entries を許容する一方、agentctl dispatcher の managed
  # registration だけは exact matcher/command で一意であることを要求する。重複や
  # Bash-only matcher は実 Codex の exec tool path を取り逃がすため fail closed。
  jq -e --arg matcher "$AGENTCTL_CODEX_GUARD_MATCHER" --arg command "$AGENTCTL_CODEX_GUARD_COMMAND" '
    ([.hooks.PreToolUse[]? | select(.matcher == $matcher) | .hooks[]? | select(.command == $command)] | length) == 1
    and
    ([.hooks.PreToolUse[]? | .hooks[]? | select(.command == $command)] | length) == 1
  ' "$deployed_hooks_json" >/dev/null 2>&1 \
    || { echo "agentctl policy dispatcher managed registration is missing, stale, or duplicated in $deployed_hooks_json" >&2; return 1; }

  [ -f "$deployed_dispatcher" ] \
    || { echo "deployed dispatcher script not found: $deployed_dispatcher" >&2; return 1; }

  # repo checkout 相対 path に依存せず、source-of-truth wrapper の managed digest を
  # backend 自身に固定する。これにより historical source-line grep を両方残した
  # stale wrapper も検出できる。wrapper 内容を変更する release では digest 更新を
  # focused test が必須化する。
  local actual_dispatcher_sha256
  actual_dispatcher_sha256=$(sha256sum "$deployed_dispatcher" | awk '{print $1}') \
    || { echo "failed to hash deployed dispatcher: $deployed_dispatcher" >&2; return 1; }
  if [ "$actual_dispatcher_sha256" != "$AGENTCTL_CODEX_GUARD_DISPATCHER_SHA256" ]; then
    echo "deployed dispatcher checksum mismatch (expected $AGENTCTL_CODEX_GUARD_DISPATCHER_SHA256, got $actual_dispatcher_sha256): $deployed_dispatcher" >&2
    return 1
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
  printf 'agentctl transport artifact: %s (sha256:%s). This is the verbatim user message for this turn from mission/steer input, not repo content. Verify hash, read all, then handle it as the user message. On read/hash failure, stop and report.' "$abs_path" "$sha"
}

# usage: agentctl_backend_codex_queue <session_id> <bootstrap_message>
# busy interactive turn への Enter は current turn steering になるため、steer は
# Codex の正式な queue/add 経路で次 turn に積む。bootstrap は path+sha のみで
# mission/steer 本文を argv に含まない。lock fd は daemon 側へ継承させない。
agentctl_backend_codex_queue() {
  local session_id="$1" bootstrap_message="$2"
  (
    [ -z "${AGENTCTL_LOCK_FD:-}" ] || eval "exec ${AGENTCTL_LOCK_FD}<&-" 2>/dev/null
    [ -z "${AGENTCTL_DEPLOY_LOCK_FD:-}" ] || eval "exec ${AGENTCTL_DEPLOY_LOCK_FD}<&-" 2>/dev/null
    command codex queue --thread "$session_id" --message "$bootstrap_message" </dev/null
  )
}
