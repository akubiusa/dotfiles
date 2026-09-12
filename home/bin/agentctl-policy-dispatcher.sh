#!/bin/bash
# agentctl 共有 PreToolUse policy dispatcher。
# Claude backend (session-local settings) と Codex backend (global hooks.json,
# home/dot_codex/hooks/executable_agentctl-policy-dispatcher.sh 経由) の両方から
# 同じ実装を source して使う。入出力契約は既存
# home/dot_codex/hooks/executable_git-config-guard.sh と同じ
# (stdin: PreToolUse payload JSON、stdout: hookSpecificOutput JSON か no-op)。
#
# AGENTCTL_POLICY_SNAPSHOT / AGENTCTL_RUNTIME_ID が無い通常 session では no-op する
# (既存 Codex/Claude behavior を変えない)。agentctl runtime ではこれらの env や
# jq 等の dependency 欠落・不一致を deny にする (fail-open にしない)。

# PreToolUse payload から shell command を安全に抽出する。
# Bash は既存 object shape、Codex exec は現行 TUI が生成する固定 JavaScript wrapper
# の内側にある JSON object だけを受理する。JavaScript 自体は評価しない。
agentctl_policy_dispatcher_extract_command_string() {
  local tool_name="$1" input="$2" tool_input="" inner=""
  case "$tool_name" in
    Bash)
      printf '%s' "$input" | jq -r '.tool_input.command // empty'
      ;;
    exec)
      tool_input=$(printf '%s' "$input" | jq -er '.tool_input | select(type == "string" and length > 0)') || return 1
      local prefix='const r = await tools.exec_command('
      local suffix=$');\ntext(r.output);'
      [[ "$tool_input" == "$prefix"*"$suffix" ]] || return 1
      inner=${tool_input#"$prefix"}
      inner=${inner%"$suffix"}
      printf '%s' "$inner" | jq -e '
        type == "object"
        and (.cmd | type == "string" and length > 0)
        and ((keys - ["cmd","max_output_tokens","workdir","yield_time_ms"]) | length == 0)
        and ((has("workdir") | not) or (.workdir | type == "string"))
        and ((has("yield_time_ms") | not) or (."yield_time_ms" | type == "number"))
        and ((has("max_output_tokens") | not) or (."max_output_tokens" | type == "number"))
      ' >/dev/null || return 1
      printf '%s' "$inner" | jq -r '.cmd'
      ;;
    *)
      return 1
      ;;
  esac
}

agentctl_policy_dispatcher_main() {
  local input
  input=$(cat)

  # agentctl env も sentinel もなく、Codex session binding 自体が1件も無い通常
  # session は JSON parse 前に即 no-op にする。global hook の常時起動コストを
  # agentctl 未使用時へ持ち込まず、binding が存在する時だけ厳密な jq 検証へ進む。
  local sessions_dir=""
  if declare -F agentctl_codex_hook_sessions_dir >/dev/null 2>&1; then
    sessions_dir=$(agentctl_codex_hook_sessions_dir)
  fi
  if { [ -z "${AGENTCTL_POLICY_SNAPSHOT:-}" ] && [ -z "${AGENTCTL_RUNTIME_ID:-}" ]; } \
    && [[ "$input" != *"agentctl-guard-sentinel:"* ]] \
    && { [ -z "$sessions_dir" ] || ! compgen -G "$sessions_dir/*.json" >/dev/null; }; then
    exit 0
  fi

  # Codex interactive TUI の persistent execution path では TUI 起動時の
  # AGENTCTL_* env が hook subprocess へ届かない。その場合でも sentinel marker
  # + hook stdin の stable session_id から runtime context を初回 binding できる。
  # jq が消失した場合、agentctl env / sentinel / 既存 Codex binding のいずれかが
  # あるなら normal session と識別できないため fail closed。binding が一切無い
  # 通常 Codex session だけは従来どおり no-op とする。
  if ! command -v jq >/dev/null 2>&1; then
    if { [ -z "${AGENTCTL_POLICY_SNAPSHOT:-}" ] && [ -z "${AGENTCTL_RUNTIME_ID:-}" ]; } \
      && [[ "$input" != *"agentctl-guard-sentinel:"* ]] \
      && { [ -z "$sessions_dir" ] || ! compgen -G "$sessions_dir/*.json" >/dev/null; }; then
      exit 0
    fi
    agentctl_policy_dispatcher_emit_deny "agentctl policy dispatcher requires jq, which is not installed"
    exit 0
  fi

  local session_id hook_cwd sentinel_marker_input="" sentinel_runtime_id="" sentinel_nonce="" context_source="env"
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
  hook_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
  sentinel_marker_input=$(printf '%s' "$input" | grep -oE 'agentctl-guard-sentinel:[A-Za-z0-9_-]+:[A-Za-z0-9_-]+' | head -n1 || true)
  if [ -n "$sentinel_marker_input" ]; then
    sentinel_runtime_id=$(printf '%s' "$sentinel_marker_input" | cut -d: -f2)
    sentinel_nonce=$(printf '%s' "$sentinel_marker_input" | cut -d: -f3)
  fi

  # nonce 付き Codex sentinel は ambient AGENTCTL_* の有無に関係なく session_id を
  # binding する。Bash tool 経路では hook subprocess が env を継承する場合がある一方、
  # 後続 `codex queue` は app-server session_id を必要とするため、sentinel 成功時に
  # session binding が必ず存在することを publication invariant にする。
  if [ -n "$sentinel_runtime_id" ]; then
    if ! agentctl_policy_dispatcher_bind_codex_sentinel "$input" "$sentinel_runtime_id" "$sentinel_nonce"; then
      agentctl_policy_dispatcher_emit_deny "${AGENTCTL_POLICY_DISPATCHER_ERROR:-failed to bind Codex sentinel session}"
      exit 0
    fi
    context_source="codex_session"
  elif [ -n "$session_id" ]; then
    if agentctl_policy_dispatcher_resolve_codex_session "$input"; then
      # sentinel 後の interactive Codex は ambient AGENTCTL_* が残っていても binding を
      # 優先する。これにより operation-file read と queue が同じ session generation を使う。
      context_source="codex_session"
    else
      local resolve_rc=$?
      if [ "$resolve_rc" -ne 3 ]; then
        agentctl_policy_dispatcher_emit_deny "${AGENTCTL_POLICY_DISPATCHER_ERROR:-invalid Codex agentctl session binding}"
        exit 0
      fi
      # binding の無い direct codex exec 等は ambient env があれば従来の env context、
      # env も無ければ通常 session として no-op を維持する。
      if [ -z "${AGENTCTL_POLICY_SNAPSHOT:-}" ] && [ -z "${AGENTCTL_RUNTIME_ID:-}" ]; then
        exit 0
      fi
    fi
  elif [ -z "${AGENTCTL_POLICY_SNAPSHOT:-}" ] && [ -z "${AGENTCTL_RUNTIME_ID:-}" ]; then
    exit 0
  fi

  local deny_reason=""
  if [ -z "${AGENTCTL_POLICY_SNAPSHOT:-}" ] || [ -z "${AGENTCTL_RUNTIME_ID:-}" ]; then
    deny_reason="agentctl runtime is missing AGENTCTL_POLICY_SNAPSHOT or AGENTCTL_RUNTIME_ID"
  elif [ ! -f "$AGENTCTL_POLICY_SNAPSHOT" ]; then
    deny_reason="agentctl policy snapshot not found: $AGENTCTL_POLICY_SNAPSHOT"
  elif ! jq -e . "$AGENTCTL_POLICY_SNAPSHOT" >/dev/null 2>&1; then
    deny_reason="agentctl policy snapshot is not valid JSON: $AGENTCTL_POLICY_SNAPSHOT"
  elif [ -z "${AGENTCTL_POLICY_DIGEST:-}" ]; then
    deny_reason="agentctl runtime is missing AGENTCTL_POLICY_DIGEST"
  else
    # publication 時に記録した digest と、実行時点の snapshot 実体を突き合わせる。
    # 一致しなければ、publish 後に同一 user 権限の別プロセス/バグが snapshot を
    # 書き換えた可能性があるとみなし fail closed する。
    local actual_digest
    actual_digest=$(jq -S -c . "$AGENTCTL_POLICY_SNAPSHOT" | sha256sum | awk '{print "sha256:" $1}')
    if [ "$actual_digest" != "$AGENTCTL_POLICY_DIGEST" ]; then
      deny_reason="agentctl policy snapshot digest mismatch (expected $AGENTCTL_POLICY_DIGEST, got $actual_digest)"
    fi
  fi

  AGENTCTL_POLICY_CONTEXT_SOURCE="$context_source"
  AGENTCTL_CODEX_SESSION_ID="$session_id"
  AGENTCTL_CODEX_HOOK_CWD="$hook_cwd"
  [ -z "$deny_reason" ] && deny_reason=$(agentctl_policy_dispatcher_check_ownership)

  if [ -n "$deny_reason" ]; then
    agentctl_policy_dispatcher_emit_deny "$deny_reason"
    exit 0
  fi

  local policy_json
  policy_json=$(cat "$AGENTCTL_POLICY_SNAPSHOT")

  local sentinel_marker="agentctl-guard-sentinel:$AGENTCTL_RUNTIME_ID"
  local tool_name
  tool_name=$(echo "$input" | jq -r '.tool_name // empty')

  # guard startup verification 用の無害な sentinel command。Codex session binding
  # 経路ではここへ到達する時点で pending runtime/state/policy/session_id の相互照合が
  # 完了しているため、この evidence が real PreToolUse 発火の機械的証拠になる。
  case "$input" in
    *"$sentinel_marker"*)
      local dir="${AGENTCTL_POLICY_SNAPSHOT%/*}" evidence_tmp
      evidence_tmp="$dir/guard-sentinel.json.tmp.$$"
      (umask 077; jq -n --arg runtime_id "$AGENTCTL_RUNTIME_ID" --arg sentinel_nonce "$sentinel_nonce" \
        '{runtime_id:$runtime_id, decision:"deny", sentinel_nonce:$sentinel_nonce}' >"$evidence_tmp") \
        && mv -f "$evidence_tmp" "$dir/guard-sentinel.json"
      agentctl_policy_dispatcher_emit_deny "agentctl guard sentinel probe (always denied)"
      exit 0
      ;;
  esac

  local command_string
  if ! command_string=$(agentctl_policy_dispatcher_extract_command_string "$tool_name" "$input"); then
    agentctl_policy_dispatcher_emit_deny "agentctl policy dispatcher cannot classify tool '$tool_name' call shape; denying by default (fail closed)"
    exit 0
  fi
  if [ -z "$command_string" ]; then
    # command を含まない Bash tool call は分類対象が無いので pass-through する。
    exit 0
  fi

  # .tool_input.command 先頭の明示的 assignment word (agentctl-classify.sh 側で検出)
  # だけでなく、hook process 自身が backend プロセスから継承した実 GIT_DIR/
  # GIT_WORK_TREE/GIT_CONFIG_* 環境変数も deny 判定に載せる。さもないと command
  # string には現れない override (親プロセス環境に既に乗っている override) を
  # 使った privileged git 操作が classifier に一切伝わらず素通りしてしまう。
  local inherited_env_csv
  inherited_env_csv=$(agentctl_policy_dispatcher_inherited_git_env_csv)

  # Codex TUI の operation-file bootstrap は model が read-only verification を
  # shell で行う。generic classifier は quote/backslash を意図的に fail closed に
  # するため、そのルールを緩めず、bound Codex session が「自分の runtime dir に
  # agentctl が生成した UUID 名 codex-op-*.txt」を読む exact shape だけを許可する。
  # prefix match はせず command 全体を byte-exact 比較するため、後置コマンドや
  # runtime 外 path はこの例外に入らず通常 classifier で fail closed になる。
  if [ "${AGENTCTL_POLICY_CONTEXT_SOURCE:-env}" = "codex_session" ] \
    && agentctl_policy_dispatcher_is_codex_operation_read "$command_string"; then
    exit 0
  fi

  local decision
  if ! decision=$(agentctl_classify_shell_command_string "$policy_json" --env "$inherited_env_csv" "$command_string"); then
    agentctl_policy_dispatcher_emit_deny "agentctl policy classifier failed to execute; denying by default (fail closed)"
    exit 0
  fi
  case "$decision" in
    allow|not_privileged)
      : # classifier が明示した既知の安全 decision だけ既定 allow を尊重する。
      ;;
    *)
      agentctl_policy_dispatcher_emit_deny "agentctl policy denied this operation (classification: ${decision:-<empty>})"
      ;;
  esac
  exit 0
}

# Codex sentinel marker に含まれる runtime_id を HOME 固定 registry の pending
# entry と照合し、hook stdin の stable session_id に atomic bind する。
# 成功時は AGENTCTL_* をこの shell 内だけに設定し 0、失敗時は
# AGENTCTL_POLICY_DISPATCHER_ERROR を設定して非 0 を返す。
agentctl_policy_dispatcher_bind_codex_sentinel() {
  local input="$1" runtime_id="$2" sentinel_nonce="$3"
  local session_id hook_cwd pending pending_json
  AGENTCTL_POLICY_DISPATCHER_ERROR=""
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
  hook_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
  if [ -z "$session_id" ] || [ -z "$hook_cwd" ]; then
    AGENTCTL_POLICY_DISPATCHER_ERROR="Codex sentinel hook input is missing session_id or cwd"
    return 1
  fi
  pending=$(agentctl_codex_hook_pending_file "$runtime_id")
  if [ ! -f "$pending" ]; then
    AGENTCTL_POLICY_DISPATCHER_ERROR="Codex sentinel has no pending agentctl runtime binding for runtime_id $runtime_id"
    return 1
  fi
  if ! pending_json=$(jq -c . "$pending" 2>/dev/null); then
    AGENTCTL_POLICY_DISPATCHER_ERROR="Codex pending runtime binding is invalid JSON"
    return 1
  fi

  local stored_schema stored_runtime_id stored_name stored_backend runtime_dir policy_snapshot policy_digest stored_cwd stored_sentinel_nonce
  stored_schema=$(echo "$pending_json" | jq -r '.schema_version // empty')
  stored_runtime_id=$(echo "$pending_json" | jq -r '.runtime_id // empty')
  stored_name=$(echo "$pending_json" | jq -r '.name // empty')
  stored_backend=$(echo "$pending_json" | jq -r '.backend // empty')
  runtime_dir=$(echo "$pending_json" | jq -r '.runtime_dir // empty')
  policy_snapshot=$(echo "$pending_json" | jq -r '.policy_snapshot // empty')
  policy_digest=$(echo "$pending_json" | jq -r '.policy_digest // empty')
  stored_cwd=$(echo "$pending_json" | jq -r '.cwd // empty')
  stored_sentinel_nonce=$(echo "$pending_json" | jq -r '.sentinel_nonce // empty')
  if [ "$stored_schema" != "$AGENTCTL_SCHEMA_VERSION" ] || [ "$stored_runtime_id" != "$runtime_id" ] \
    || [ "$stored_backend" != "codex" ] || [ -z "$stored_name" ] || [ "$stored_cwd" != "$hook_cwd" ] \
    || [ -z "$sentinel_nonce" ] || [ "$stored_sentinel_nonce" != "$sentinel_nonce" ] \
    || [[ "$runtime_dir" != /* ]] || [[ "$policy_snapshot" != /* ]]; then
    AGENTCTL_POLICY_DISPATCHER_ERROR="Codex pending runtime binding does not match sentinel hook identity"
    return 1
  fi

  local state_file="$runtime_dir/state.json" state_json
  if ! state_json=$(jq -c . "$state_file" 2>/dev/null); then
    AGENTCTL_POLICY_DISPATCHER_ERROR="Codex pending runtime state is missing or invalid"
    return 1
  fi
  if ! echo "$state_json" | jq -e \
    --arg rid "$runtime_id" --arg name "$stored_name" --arg cwd "$hook_cwd" --argjson schema "$AGENTCTL_SCHEMA_VERSION" \
    '.schema_version == $schema and .runtime_id == $rid and .name == $name and .backend == "codex" and .cwd == $cwd and (.status == "starting" or .status == "running")' \
    >/dev/null 2>&1; then
    AGENTCTL_POLICY_DISPATCHER_ERROR="Codex pending runtime state does not match this generation/session"
    return 1
  fi
  if [ ! -f "$policy_snapshot" ]; then
    AGENTCTL_POLICY_DISPATCHER_ERROR="Codex pending policy snapshot not found: $policy_snapshot"
    return 1
  fi
  local actual_digest
  actual_digest=$(jq -S -c . "$policy_snapshot" | sha256sum | awk '{print "sha256:" $1}')
  if [ "$actual_digest" != "$policy_digest" ]; then
    AGENTCTL_POLICY_DISPATCHER_ERROR="Codex pending policy snapshot digest mismatch"
    return 1
  fi

  agentctl_codex_hook_registry_ensure
  local session_file existing
  session_file=$(agentctl_codex_hook_session_file "$session_id")
  if [ -f "$session_file" ]; then
    if ! existing=$(jq -c . "$session_file" 2>/dev/null) \
      || ! echo "$existing" | jq -e --arg sid "$session_id" --arg rid "$runtime_id" --arg dir "$runtime_dir" \
        '.session_id == $sid and .runtime_id == $rid and .runtime_dir == $dir' >/dev/null 2>&1; then
      AGENTCTL_POLICY_DISPATCHER_ERROR="Codex session_id is already bound to a different agentctl runtime generation"
      return 1
    fi
  else
    jq -n \
      --argjson schema_version "$AGENTCTL_SCHEMA_VERSION" \
      --arg session_id "$session_id" --arg runtime_id "$runtime_id" --arg name "$stored_name" \
      --arg runtime_dir "$runtime_dir" --arg policy_snapshot "$policy_snapshot" \
      --arg policy_digest "$policy_digest" --arg cwd "$hook_cwd" \
      '{schema_version:$schema_version,session_id:$session_id,runtime_id:$runtime_id,name:$name,backend:"codex",runtime_dir:$runtime_dir,policy_snapshot:$policy_snapshot,policy_digest:$policy_digest,cwd:$cwd}' \
      | agentctl_atomic_write "$session_file" 0600
  fi
  rm -f "$pending"

  AGENTCTL_RUNTIME_ID="$runtime_id"
  AGENTCTL_POLICY_SNAPSHOT="$policy_snapshot"
  AGENTCTL_POLICY_DIGEST="$policy_digest"
  AGENTCTL_CODEX_BINDING_FILE="$session_file"
  return 0
}

# 既に sentinel で bind 済みの Codex session_id から context を復元する。
# binding 自体が無い場合だけ return 3 (通常 Codex session の no-op 判定用)。
agentctl_policy_dispatcher_resolve_codex_session() {
  local input="$1" session_id hook_cwd session_file binding
  AGENTCTL_POLICY_DISPATCHER_ERROR=""
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
  hook_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
  [ -n "$session_id" ] || return 3
  session_file=$(agentctl_codex_hook_session_file "$session_id")
  [ -f "$session_file" ] || return 3
  if ! binding=$(jq -c . "$session_file" 2>/dev/null); then
    AGENTCTL_POLICY_DISPATCHER_ERROR="Codex session binding is invalid JSON"
    return 1
  fi

  local stored_schema stored_session_id runtime_id backend runtime_dir policy_snapshot policy_digest stored_cwd
  stored_schema=$(echo "$binding" | jq -r '.schema_version // empty')
  stored_session_id=$(echo "$binding" | jq -r '.session_id // empty')
  runtime_id=$(echo "$binding" | jq -r '.runtime_id // empty')
  backend=$(echo "$binding" | jq -r '.backend // empty')
  runtime_dir=$(echo "$binding" | jq -r '.runtime_dir // empty')
  policy_snapshot=$(echo "$binding" | jq -r '.policy_snapshot // empty')
  policy_digest=$(echo "$binding" | jq -r '.policy_digest // empty')
  stored_cwd=$(echo "$binding" | jq -r '.cwd // empty')
  if [ "$stored_schema" != "$AGENTCTL_SCHEMA_VERSION" ] || [ "$stored_session_id" != "$session_id" ] \
    || [ "$backend" != "codex" ] || [ -z "$runtime_id" ] || [ "$stored_cwd" != "$hook_cwd" ] \
    || [[ "$runtime_dir" != /* ]] || [[ "$policy_snapshot" != /* ]]; then
    AGENTCTL_POLICY_DISPATCHER_ERROR="Codex session binding identity mismatch"
    return 1
  fi

  AGENTCTL_RUNTIME_ID="$runtime_id"
  AGENTCTL_POLICY_SNAPSHOT="$policy_snapshot"
  AGENTCTL_POLICY_DIGEST="$policy_digest"
  AGENTCTL_CODEX_BINDING_FILE="$session_file"
  return 0
}

# runtime ownership/generation を state.json と突き合わせる。
# Claude/env 経路は従来どおり live tmux pane marker を要求する。Codex interactive
# TUI は hook subprocess に TMUX_PANE/AGENTCTL_* が継承されないため、sentinel で
# bind した Codex session_id record + runtime state/cwd/backend/generation を毎回
# 再照合する。どちらの経路でも stale generation は fail closed。
agentctl_policy_dispatcher_check_ownership() {
  local policy_version
  policy_version=$(jq -r '.version // empty' "$AGENTCTL_POLICY_SNAPSHOT")
  if [ "$policy_version" != "1" ]; then
    echo "agentctl policy version is unsupported (got: $policy_version)"
    return
  fi

  local dir="${AGENTCTL_POLICY_SNAPSHOT%/*}" state_file
  state_file="$dir/state.json"
  if [ ! -f "$state_file" ]; then
    echo "agentctl runtime state not found: $state_file"
    return
  fi
  local state_json
  if ! state_json=$(jq -c . "$state_file" 2>/dev/null); then
    echo "agentctl runtime state is not valid JSON: $state_file"
    return
  fi

  local state_runtime_id state_name state_backend state_schema state_cwd
  state_runtime_id=$(echo "$state_json" | jq -r '.runtime_id // empty')
  state_name=$(echo "$state_json" | jq -r '.name // empty')
  state_backend=$(echo "$state_json" | jq -r '.backend // empty')
  state_schema=$(echo "$state_json" | jq -r '.schema_version // empty')
  state_cwd=$(echo "$state_json" | jq -r '.cwd // empty')
  if [ "$state_runtime_id" != "$AGENTCTL_RUNTIME_ID" ]; then
    echo "agentctl runtime state runtime_id does not match this generation (possibly superseded)"
    return
  fi

  if [ "${AGENTCTL_POLICY_CONTEXT_SOURCE:-env}" = "codex_session" ]; then
    local binding_file="${AGENTCTL_CODEX_BINDING_FILE:-}" binding_json
    if [ "$state_backend" != "codex" ] || [ "$state_schema" != "$AGENTCTL_SCHEMA_VERSION" ] \
      || [ -z "$state_name" ] || [ -z "$state_cwd" ] || [ "$state_cwd" != "${AGENTCTL_CODEX_HOOK_CWD:-}" ]; then
      echo "Codex session binding does not match runtime state identity"
      return
    fi
    if [ -z "$binding_file" ] || ! binding_json=$(jq -c . "$binding_file" 2>/dev/null); then
      echo "Codex session binding file is missing or invalid"
      return
    fi
    if ! echo "$binding_json" | jq -e \
      --arg sid "${AGENTCTL_CODEX_SESSION_ID:-}" \
      --arg rid "$AGENTCTL_RUNTIME_ID" \
      --arg name "$state_name" \
      --arg dir "$dir" \
      --arg policy "$AGENTCTL_POLICY_SNAPSHOT" \
      --arg digest "$AGENTCTL_POLICY_DIGEST" \
      --arg cwd "$state_cwd" \
      --argjson schema "$AGENTCTL_SCHEMA_VERSION" \
      '.schema_version == $schema and .session_id == $sid and .runtime_id == $rid and .name == $name and .backend == "codex" and .runtime_dir == $dir and .policy_snapshot == $policy and .policy_digest == $digest and .cwd == $cwd' \
      >/dev/null 2>&1; then
      echo "Codex session binding was changed or does not match runtime generation"
      return
    fi
    return 0
  fi

  if [ -z "${TMUX_PANE:-}" ]; then
    echo "agentctl runtime tmux pane ownership evidence missing (TMUX_PANE not set)"
    return
  fi
  local marker_owner marker_runtime_id marker_name marker_backend marker_schema
  marker_owner=$(command tmux show-options -p -t "$TMUX_PANE" -v "@agentctl_owner" 2>/dev/null)
  marker_runtime_id=$(command tmux show-options -p -t "$TMUX_PANE" -v "@agentctl_runtime_id" 2>/dev/null)
  marker_name=$(command tmux show-options -p -t "$TMUX_PANE" -v "@agentctl_name" 2>/dev/null)
  marker_backend=$(command tmux show-options -p -t "$TMUX_PANE" -v "@agentctl_backend" 2>/dev/null)
  marker_schema=$(command tmux show-options -p -t "$TMUX_PANE" -v "@agentctl_schema_version" 2>/dev/null)
  if [ "$marker_owner" != "agentctl" ] || [ "$marker_runtime_id" != "$state_runtime_id" ] \
    || [ "$marker_name" != "$state_name" ] || [ "$marker_backend" != "$state_backend" ] \
    || [ "$marker_schema" != "$state_schema" ]; then
    echo "agentctl runtime tmux pane ownership marker missing or mismatched"
    return
  fi
}

# 使い方: agentctl_policy_dispatcher_is_codex_operation_read <command_string>
# 成功(0): current runtime dir 内の agentctl-generated operation file に対する
# exact read-only bootstrap command。失敗(1): それ以外。
agentctl_policy_dispatcher_matches_codex_operation_read_operand() {
  local command_string="$1" operand="$2" prefix suffix range

  # Codex が verification と本文 read を別々の read-only call に分ける場合もある。
  # 許可する形はすべて同一の既知 operation-file operand に限定する。
  [ "$command_string" = "sha256sum $operand && wc -c $operand" ] && return 0

  prefix="sed -n '"
  suffix="p' $operand"
  if [[ "$command_string" == "$prefix"*"$suffix" ]]; then
    range=${command_string#"$prefix"}
    range=${range%"$suffix"}
    [[ "$range" =~ ^[1-9][0-9]*,([1-9][0-9]*|\$)$ ]] && return 0
  fi

  prefix="sha256sum $operand && sed -n '"
  suffix="p' $operand"
  if [[ "$command_string" == "$prefix"*"$suffix" ]]; then
    range=${command_string#"$prefix"}
    range=${range%"$suffix"}
    [[ "$range" =~ ^[1-9][0-9]*,([1-9][0-9]*|\$)$ ]] && return 0
  fi

  prefix="sha256sum $operand && wc -c $operand && sed -n '"
  suffix="p' $operand"
  if [[ "$command_string" == "$prefix"*"$suffix" ]]; then
    range=${command_string#"$prefix"}
    range=${range%"$suffix"}
    [[ "$range" =~ ^[1-9][0-9]*,([1-9][0-9]*|\$)$ ]] && return 0
  fi

  return 1
}

agentctl_policy_dispatcher_is_codex_operation_read() {
  local command_string="$1" dir file base operand escaped
  local artifact_count=0
  dir="${AGENTCTL_POLICY_SNAPSHOT%/*}"
  [ -d "$dir" ] || return 1

  # transport artifact は backend 側で64件に制限する。古い実装や手動改変で
  # それを超えた runtime は例外判定を止め、通常 classifier に戻して fail closed にする。
  for file in "$dir"/codex-op-*.txt; do
    [ -f "$file" ] || continue
    artifact_count=$((artifact_count + 1))
    [ "$artifact_count" -le 64 ] || return 1
  done

  for file in "$dir"/codex-op-*.txt; do
    [ -f "$file" ] || continue
    base=${file##*/}
    [[ "$base" =~ ^codex-op-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.txt$ ]] || continue

    # Codex が生成する read-only shape。sed の上限行数は file/context
    # に応じて 240/260 等へ変化するため正の整数だけ許容し、それ以外の command
    # token と同一 operation-file operand の3回使用は完全一致を要求する。
    # runtime path に空白/metacharacter があっても raw unquoted operand は絶対に
    # allow しない。Bash %q variant と、single-quote を含まない path の
    # single-quoted variant だけを exact match する。
    printf -v escaped '%q' "$file"
    agentctl_policy_dispatcher_matches_codex_operation_read_operand "$command_string" "$escaped" && return 0

    if [[ "$file" != *"'"* ]]; then
      operand="'$file'"
      agentctl_policy_dispatcher_matches_codex_operation_read_operand "$command_string" "$operand" && return 0
    fi
  done
  return 1
}

# dispatcher プロセス自身の実環境から Git/GitHub identity を変え得る override
# (GIT_DIR/GIT_WORK_TREE/GIT_CONFIG_* と GH_HOST) を集め、classifier の --env
# と同じ "K=V,K=V" 形式で返す。
agentctl_policy_dispatcher_inherited_git_env_csv() {
  local var csv=""
  while IFS= read -r var; do
    case "$var" in
      GIT_DIR|GIT_WORK_TREE|GIT_CONFIG_*|GH_HOST)
        csv="${csv}${var}=${!var},"
        ;;
    esac
  done < <(compgen -v)
  echo "$csv"
}

agentctl_policy_dispatcher_emit_deny() {
  # jq 自体が無い場合に deny を jq 生成できず fail-open するのを避けるため、
  # jq が使える場合だけ整形して reason を埋め込み、無ければ printf の固定文字列で
  # deny を返す (reason のエスケープはできないが決定自体は必ず deny になる)。
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg reason "$1" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"agentctl policy dispatcher dependency missing (jq)"}}\n'
  fi
}

# source された場合 (テストから関数だけ使う場合) は実行しない。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/agentctl-common.sh"
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/agentctl-classify.sh"
  agentctl_policy_dispatcher_main
fi
