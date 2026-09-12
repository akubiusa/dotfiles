#!/bin/bash
# Codex 用 global PreToolUse dispatcher の thin wrapper。
# 実装本体は home/bin/agentctl-policy-dispatcher.sh (Claude backend の
# session-local hook からも同じ実装を直接参照する共有ロジック)。
# Codex interactive TUI では hook subprocess に AGENTCTL_* が継承されないため、
# dispatcher 自身が sentinel/session binding を解決する。binding の無い通常 Codex
# session は dispatcher 側で no-op する。

# shellcheck disable=SC1091
source "$HOME/bin/agentctl-common.sh" 2>/dev/null || {
  jq -n --arg reason "agentctl-common.sh not found or failed to load" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}
# shellcheck disable=SC1091
source "$HOME/bin/agentctl-classify.sh" 2>/dev/null || {
  jq -n --arg reason "agentctl-classify.sh not found or failed to load" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}
# shellcheck disable=SC1091
source "$HOME/bin/agentctl-policy-dispatcher.sh"
agentctl_policy_dispatcher_main
