#!/bin/bash
set -euo pipefail

HOOK="home/dot_claude/hooks/executable_claudectl-git-guard.sh"

[[ -f "$HOOK" ]] || {
    echo "❌ claudectl Git guard is missing"
    exit 1
}

assert_denied() {
    local command="$1"
    local output
    output=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}\n' "$command" | bash "$HOOK")
    jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "$output" > /dev/null || {
        echo "❌ guard allowed: $command"
        exit 1
    }
}

assert_allowed() {
    local command="$1"
    if ! printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}\n' "$command" | bash "$HOOK" > /dev/null; then
        echo "❌ guard denied: $command"
        exit 1
    fi
}

assert_denied 'git push origin main'
assert_denied 'npm test && git merge feature'
assert_denied 'git status; gh pr merge 42'
assert_allowed 'git status && git commit -m test'
assert_allowed 'gh pr view 42'

echo "✅ claudectl managed Git guard denies only push and merge"
