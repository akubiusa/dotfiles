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

agentctl_policy_dispatcher_main() {
  if [ -z "${AGENTCTL_POLICY_SNAPSHOT:-}" ] && [ -z "${AGENTCTL_RUNTIME_ID:-}" ]; then
    exit 0
  fi

  local deny_reason=""
  if [ -z "${AGENTCTL_POLICY_SNAPSHOT:-}" ] || [ -z "${AGENTCTL_RUNTIME_ID:-}" ]; then
    deny_reason="agentctl runtime is missing AGENTCTL_POLICY_SNAPSHOT or AGENTCTL_RUNTIME_ID"
  elif ! command -v jq >/dev/null 2>&1; then
    deny_reason="agentctl policy dispatcher requires jq, which is not installed"
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

  if [ -n "$deny_reason" ]; then
    agentctl_policy_dispatcher_emit_deny "$deny_reason"
    exit 0
  fi

  local policy_json
  policy_json=$(cat "$AGENTCTL_POLICY_SNAPSHOT")

  local input
  input=$(cat)
  local command_string
  command_string=$(echo "$input" | jq -r '.tool_input.command // empty')
  if [ -z "$command_string" ]; then
    # command を含まない tool call (Bash 以外) はここに来ない想定だが、
    # 万一来た場合は分類対象が無いので pass-through する。
    exit 0
  fi

  local decision
  decision=$(agentctl_classify_shell_command_string "$policy_json" "$command_string")
  case "$decision" in
    deny|unknown_privileged)
      agentctl_policy_dispatcher_emit_deny "agentctl policy denied this operation (classification: $decision)"
      ;;
    *) : ;; # allow / not_privileged は no-op (既定 allow を尊重する)
  esac
  exit 0
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
  source "$SCRIPT_DIR/agentctl-classify.sh"
  agentctl_policy_dispatcher_main
fi
