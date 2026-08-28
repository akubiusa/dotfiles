#!/bin/bash

set -euo pipefail

input=$(cat)
command=$(jq -r '.tool_input.command // empty' <<< "$input")

[[ -n "$command" ]] || exit 0
if [[ "$command" =~ (^|[[:space:];|&])git[[:space:]]+(push|merge)([[:space:]]|$) ]] || [[ "$command" =~ (^|[[:space:];|&])gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$) ]]; then
    jq -n --arg reason 'Managed claudectl sessions cannot run git push, git merge, or gh pr merge.' '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
fi
