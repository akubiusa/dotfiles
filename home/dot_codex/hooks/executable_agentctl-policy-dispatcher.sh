#!/bin/bash
# Codex 用 global PreToolUse dispatcher の thin wrapper。
# 実装本体は home/bin/agentctl-policy-dispatcher.sh (Claude backend の
# session-local hook からも同じ実装を直接参照する共有ロジック)。
# AGENTCTL_POLICY_SNAPSHOT/AGENTCTL_RUNTIME_ID が無い通常 Codex session では
# no-op し、既存 home/dot_codex/hooks/executable_git-config-guard.sh の動作を変えない。

if [ -z "${AGENTCTL_POLICY_SNAPSHOT:-}" ] && [ -z "${AGENTCTL_RUNTIME_ID:-}" ]; then
  exit 0
fi

# shellcheck disable=SC1091
source "$HOME/bin/agentctl-classify.sh" 2>/dev/null || {
  jq -n --arg reason "agentctl-classify.sh not found or failed to load" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}
# shellcheck disable=SC1091
source "$HOME/bin/agentctl-policy-dispatcher.sh"
agentctl_policy_dispatcher_main
