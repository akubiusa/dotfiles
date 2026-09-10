#!/bin/bash
# shellcheck disable=SC2015,SC2016
# SC2015: `check && pass || fail` は本テストの意図通り。
# SC2016: backtick fixture は意図的な literal string (展開させない)。
# agentctl-classify.sh の typed-operation classifier テスト。
# real git repo fixture を使い、-C/remote push_url 解決を実測する。

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CLASSIFY="$REPO_ROOT/home/bin/agentctl-classify.sh"
# shellcheck disable=SC1090
source "$CLASSIFY"

command -v jq >/dev/null 2>&1 || { echo "⚠️  jq not found; skipping classifier tests"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "⚠️  git not found; skipping classifier tests"; exit 0; }

FAILED=0
fail() { echo "❌ $*"; FAILED=1; }
pass() { echo "✅ $*"; }

WORKROOT=$(mktemp -d)
trap 'rm -rf "$WORKROOT"' EXIT

REPO="$WORKROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
# -c core.hooksPath=: グローバル pre-commit (gitleaks) hook を fixture repo で無効化する。
git -C "$REPO" -c core.hooksPath=/dev/null commit -q --allow-empty -m init
git -C "$REPO" remote add origin git@github.com:acme/widgets.git
GIT_COMMON_DIR=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)

ALLOWED_ROOT="$WORKROOT/worktrees"
mkdir -p "$ALLOWED_ROOT"

POLICY=$(jq -n --arg gcd "$GIT_COMMON_DIR" --arg gh "acme/widgets" --arg root "$ALLOWED_ROOT" '
{
  permissions: {commit:true, push:true, create_pr:true, merge:true, git_cleanup:true, deploy:true, production_verify:false},
  repository: {git_common_dir:$gcd, github_repo:$gh, allowed_worktree_roots:[$root]},
  remotes: [{name:"origin", push_url:"git@github.com:acme/widgets.git"}],
  production_targets: [{deploy_argv:[["/abs/deploy","--target","pine"]], verify_argv:[]}]
}')
POLICY_DENY=$(echo "$POLICY" | jq '.permissions = {commit:false, push:false, create_pr:false, merge:false, git_cleanup:false, deploy:false, production_verify:false}')

check() {
  local desc="$1" expected="$2"; shift 2
  local got
  got=$(agentctl_classify_command "$@")
  [ "$got" = "$expected" ] && pass "$desc" || fail "$desc (expected $expected, got $got)"
}

# --- git push -----------------------------------------------------------

check "allowed: git -C <worktree> push origin" allow "$POLICY" -- git -C "$REPO" push origin
check "denied: git push origin (no -C)" deny "$POLICY" -- git push origin
check "denied: git -C <relative> push origin" deny "$POLICY" -- git -C repo push origin
check "denied: multiple -C" deny "$POLICY" -- git -C "$REPO" -C "$REPO" push origin
check "denied: URL direct push" deny "$POLICY" -- git -C "$REPO" push git@github.com:acme/widgets.git
check "denied: force push --force" deny "$POLICY" -- git -C "$REPO" push --force origin
check "denied: force push -f" deny "$POLICY" -- git -C "$REPO" push -f origin
check "denied: force push --force-with-lease" deny "$POLICY" -- git -C "$REPO" push --force-with-lease origin
check "denied: git --git-dir override" deny "$POLICY" -- git --git-dir="$GIT_COMMON_DIR" push origin
check "denied: git --work-tree override" deny "$POLICY" -- git --work-tree="$REPO" -C "$REPO" push origin
check "denied: git -c override" deny "$POLICY" -- git -c user.name=x -C "$REPO" push origin
check "denied: GIT_DIR env override" deny "$POLICY" --env "GIT_DIR=$GIT_COMMON_DIR" -- git -C "$REPO" push origin
check "denied: push permission=false" deny "$POLICY_DENY" -- git -C "$REPO" push origin
check "denied: remote delete without git_cleanup" deny "$(echo "$POLICY" | jq '.permissions.git_cleanup=false')" -- git -C "$REPO" push origin --delete some-branch
check "allowed: remote delete with push+git_cleanup" allow "$POLICY" -- git -C "$REPO" push origin --delete some-branch

# --- git commit / branch / worktree -----------------------------------------------------------

check "allowed: git -C <repo> commit" allow "$POLICY" -- git -C "$REPO" commit -m msg
check "denied: git -C <repo> commit (permission=false)" deny "$POLICY_DENY" -- git -C "$REPO" commit -m msg
check "not_privileged: git status" not_privileged "$POLICY" -- git status
check "not_privileged: git -C <repo> fetch" not_privileged "$POLICY" -- git -C "$REPO" fetch
check "allowed: git branch -D cleanup" allow "$POLICY" -- git -C "$REPO" branch -D mission-branch
check "not_privileged: git branch (list)" not_privileged "$POLICY" -- git -C "$REPO" branch

check "allowed: git worktree add within allowed root" allow "$POLICY" -- git -C "$REPO" worktree add "$ALLOWED_ROOT/wt1" -b wt1
check "denied: git worktree add outside allowed root" deny "$POLICY" -- git -C "$REPO" worktree add "$WORKROOT/outside" -b wt2
check "denied: git worktree add relative target" deny "$POLICY" -- git -C "$REPO" worktree add relative-wt -b wt3

# --- gh -----------------------------------------------------------

check "allowed: gh pr create --repo OWNER/REPO" allow "$POLICY" -- gh pr create --repo acme/widgets --title t --body b
check "denied: gh pr create without --repo" deny "$POLICY" -- gh pr create --title t --body b
check "denied: gh pr merge --repo (permission=false)" deny "$POLICY_DENY" -- gh pr merge --repo acme/widgets --squash
check "allowed: gh pr merge -R OWNER/REPO" allow "$POLICY" -- gh pr merge -R acme/widgets --squash
check "not_privileged: gh repo view" not_privileged "$POLICY" -- gh repo view

# --- shell wrapper / eval -----------------------------------------------------------

check "unknown_privileged: bash -c wrapping git push" unknown_privileged "$POLICY" -- bash -c "git -C $REPO push origin"
check "not_privileged: bash -c unrelated command" not_privileged "$POLICY" -- bash -c "ls -la"
check "unknown_privileged: eval wrapping gh pr merge" unknown_privileged "$POLICY" -- eval "gh pr merge --repo acme/widgets"

# --- production deploy -----------------------------------------------------------

check "allowed: exact deploy_argv match" allow "$POLICY" -- /abs/deploy --target pine
check "not_privileged: unknown executable" not_privileged "$POLICY" -- /abs/other --target pine

# --- raw shell command string entry point (PreToolUse payload 契約) -----------------------------------------------------------

check_str() {
  local desc="$1" expected="$2" policy="$3" cmd="$4"
  local got
  got=$(agentctl_classify_shell_command_string "$policy" "$cmd")
  [ "$got" = "$expected" ] && pass "$desc" || fail "$desc (expected $expected, got $got)"
}

check_str "allowed: plain string form of git -C push" allow "$POLICY" "git -C $REPO push origin"
check_str "denied: plain string form of git push (no -C)" deny "$POLICY" "git push origin"
check_str "not_privileged: plain string ls -la" not_privileged "$POLICY" "ls -la"
check_str "unknown_privileged: command substitution" unknown_privileged "$POLICY" "echo \$(git -C $REPO push origin)"
check_str "unknown_privileged: backtick substitution" unknown_privileged "$POLICY" 'echo `whoami`'
check_str "denied: chained segments with a denied git push" deny "$POLICY" "ls -la && git push origin"
check_str "allowed: chained not_privileged + allowed git commit" allow "$POLICY" "ls -la && git -C $REPO commit -m msg"
check_str "not_privileged: chained clearly non-privileged segments" not_privileged "$POLICY" "ls -la; cat foo.txt"

# --- clearly non-privileged -----------------------------------------------------------

check "not_privileged: ls" not_privileged "$POLICY" -- ls -la
check "not_privileged: cat file" not_privileged "$POLICY" -- cat somefile.txt

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl-classify unit tests passed."
else
  echo "Some agentctl-classify unit tests FAILED."
fi
exit "$FAILED"
