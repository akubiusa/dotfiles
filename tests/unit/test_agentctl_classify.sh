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
  version: 1,
  permissions: {local_write:true, commit:true, push:true, create_pr:true, merge:true, git_cleanup:true, deploy:true, production_verify:false},
  scope: {
    repositories: [{id:"primary", git_common_dir:$gcd, github_repo:$gh, allowed_worktree_roots:[$root]}],
    remotes: [{repository_id:"primary", name:"origin", push_url:"git@github.com:acme/widgets.git"}],
    production_targets: [{id:"pine", deploy_argv:[["/abs/deploy","--target","pine"]], verify_argv:[]}]
  }
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
check "denied: git worktree add traversal escape (uncreated destination under an allowed root textually, but canonically outside)" deny "$POLICY" -- git -C "$REPO" worktree add "$ALLOWED_ROOT/../escape" -b wtx
check "allowed: git worktree prune with git_cleanup=true" allow "$POLICY" -- git -C "$REPO" worktree prune
check "denied: git worktree prune with git_cleanup=false" deny "$(echo "$POLICY" | jq '.permissions.git_cleanup=false')" -- git -C "$REPO" worktree prune

check "denied: push --prune requires git_cleanup" deny "$(echo "$POLICY" | jq '.permissions.git_cleanup=false')" -- git -C "$REPO" push --prune origin
check "allowed: push --prune with git_cleanup=true" allow "$POLICY" -- git -C "$REPO" push --prune origin
check "denied: push --mirror is always denied (equivalent to force-push)" deny "$POLICY" -- git -C "$REPO" push --mirror origin

# --- gh -----------------------------------------------------------

check "allowed: gh pr create --repo OWNER/REPO" allow "$POLICY" -- gh pr create --repo acme/widgets --title t --body b
check "denied: gh pr create without --repo" deny "$POLICY" -- gh pr create --title t --body b
check "denied: gh pr merge --repo (permission=false)" deny "$POLICY_DENY" -- gh pr merge --repo acme/widgets --squash
check "allowed: gh pr merge -R OWNER/REPO" allow "$POLICY" -- gh pr merge -R acme/widgets --squash
check "not_privileged: gh repo view" not_privileged "$POLICY" -- gh repo view

# --- shell wrapper / eval -----------------------------------------------------------

check "unknown_privileged: bash -c wrapping git push" unknown_privileged "$POLICY" -- bash -c "git -C $REPO push origin"
check "unknown_privileged: shell interpreter wrapper is fail-closed even when its script text looks unrelated" unknown_privileged "$POLICY" -- bash -c "ls -la"
check "unknown_privileged: source builtin is fail-closed because sourced file contents are not statically classified" unknown_privileged "$POLICY" -- source ./script.sh
check "unknown_privileged: dot/source builtin is fail-closed because sourced file contents are not statically classified" unknown_privileged "$POLICY" -- . ./script.sh
check "unknown_privileged: eval wrapping gh pr merge" unknown_privileged "$POLICY" -- eval "gh pr merge --repo acme/widgets"

# --- production deploy -----------------------------------------------------------

check "allowed: exact deploy_argv match" allow "$POLICY" -- /abs/deploy --target pine
check "not_privileged: unknown executable" not_privileged "$POLICY" -- /abs/other --target pine
check "unknown_privileged: bash -c wrapping a production deploy_argv executable" unknown_privileged "$POLICY" -- bash -c "/abs/deploy --target pine"
check "unknown_privileged: eval wrapping a production deploy_argv executable" unknown_privileged "$POLICY" -- eval "/abs/deploy --target pine"
check "denied: same production executable with an unapproved target argv" deny "$POLICY" -- /abs/deploy --target production
check "denied: same production executable with extra trailing argv" deny "$POLICY" -- /abs/deploy --target pine --force
check "not_privileged: unconfigured executable that merely resembles the production one" not_privileged "$POLICY" -- /abs/deploy-staging --target pine

# --- production deploy: real-executable canonicalization (v8 audit finding) -----------------------------------------------------------

mkdir -p "$WORKROOT/bin"
printf '#!/bin/bash\nexit 0\n' >"$WORKROOT/bin/deploy"
chmod +x "$WORKROOT/bin/deploy"
ln -s "$WORKROOT/bin/deploy" "$WORKROOT/deploy-link"
POLICY_REALEXEC=$(echo "$POLICY" | jq --arg exe "$WORKROOT/bin/deploy" \
  '.scope.production_targets += [{id:"real",deploy_argv:[[$exe,"--target","production"]],verify_argv:[]}]')

check "allowed: canonical production executable path" allow "$POLICY_REALEXEC" -- "$WORKROOT/bin/deploy" --target production
check "allowed: same production executable via ../ traversal resolves to the same canonical identity" allow "$POLICY_REALEXEC" -- "$WORKROOT/bin/../bin/deploy" --target production
check "allowed: same production executable via symlink resolves to the same canonical identity" allow "$POLICY_REALEXEC" -- "$WORKROOT/deploy-link" --target production
check "denied: canonical production executable with unapproved argv" deny "$POLICY_REALEXEC" -- "$WORKROOT/bin/deploy" --target staging
check "denied: same production executable via symlink with unapproved argv" deny "$POLICY_REALEXEC" -- "$WORKROOT/deploy-link" --target staging

# --- shell env-prefix (leading POSIX assignment word) -----------------------------------------------------------
# `FOO=bar git ...` / `GIT_DIR=x git ...` / `X=1 gh ...` は argv[0] が assignment
# word になるため、剥がさなければ git/gh 判定に一切乗らず not_privileged
# (暗黙 allow) にすり抜ける。

check "denied: any leading env-assignment word before a privileged git mutation denies (v8 design.md:112ff)" deny "$POLICY" -- FOO=bar git -C "$REPO" commit -m msg
check "denied: ordinary FOO=bar env prefix on a policy-denied commit still denies" deny "$POLICY_DENY" -- FOO=bar git -C "$REPO" commit -m msg
check "denied: env-wrapped privileged git mutation denies even with zero assignments" deny "$POLICY" -- env git -C "$REPO" commit -m msg
check "not_privileged: leading env-assignment before a non-privileged git op is unaffected" not_privileged "$POLICY" -- FOO=bar git -C "$REPO" fetch
check "denied: GIT_DIR env-prefix word before git -C push" deny "$POLICY" -- GIT_DIR=/tmp/evil git -C "$REPO" push origin
check "denied: GIT_WORK_TREE env-prefix word before git -C push" deny "$POLICY" -- GIT_WORK_TREE=/tmp/evil git -C "$REPO" push origin
check "denied: GIT_CONFIG_COUNT env-prefix word before git -C push" deny "$POLICY" -- GIT_CONFIG_COUNT=1 git -C "$REPO" push origin
check "unknown_privileged: any env prefix before gh pr merge (no known-safe allowlist)" unknown_privileged "$POLICY" -- X=1 gh pr merge --repo acme/widgets --squash
check "not_privileged: ordinary FOO=bar env prefix on a non-privileged command is unaffected" not_privileged "$POLICY" -- FOO=bar ls -la
check "denied: multiple chained env-prefix words before git push (GIT_DIR among them)" deny "$POLICY" -- A=1 GIT_DIR=/tmp/evil git -C "$REPO" push origin

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
check_str "unknown_privileged: parameter expansion that can synthesize a command name fails closed" unknown_privileged "$POLICY" 'G=git; $G -C /tmp/repo push origin'
check_str "unknown_privileged: braced parameter expansion fails closed" unknown_privileged "$POLICY" 'echo ${HOME}'
check_str "unknown_privileged: pathname glob expansion fails closed" unknown_privileged "$POLICY" 'g* -C /tmp/repo push origin'
check_str "unknown_privileged: brace expansion fails closed" unknown_privileged "$POLICY" 'g{it,h} -C /tmp/repo push origin'
# shellcheck disable=SC2088  # literal raw shell input; expansion must be classified, not performed by this test shell.
check_str "unknown_privileged: tilde expansion fails closed" unknown_privileged "$POLICY" '~/bin/git -C /tmp/repo push origin'
check_str "unknown_privileged: raw source builtin fails closed" unknown_privileged "$POLICY" 'source ./script.sh'
check_str "unknown_privileged: raw dot/source builtin fails closed" unknown_privileged "$POLICY" '. ./script.sh'
check_str "denied: chained segments with a denied git push" deny "$POLICY" "ls -la && git push origin"
check_str "allowed: chained not_privileged + allowed git commit" allow "$POLICY" "ls -la && git -C $REPO commit -m msg"
check_str "not_privileged: chained clearly non-privileged segments" not_privileged "$POLICY" "ls -la; cat foo.txt"

# --- raw shell command string: env-prefix / production near-match (実 PreToolUse 契約経由) -----------------------------------------------------------

check_str "denied: raw string leading env-assignment before a privileged git commit denies" deny "$POLICY" "FOO=bar git -C $REPO commit -m msg"
check_str "denied: raw string GIT_DIR env prefix before git push" deny "$POLICY" "GIT_DIR=/tmp/evil git -C $REPO push origin"
check_str "unknown_privileged: raw string env prefix before gh pr merge" unknown_privileged "$POLICY" "X=1 gh pr merge --repo acme/widgets --squash"
check_str "denied: raw string same production executable with unapproved target" deny "$POLICY" "/abs/deploy --target production"
check_str "allowed: raw string exact production deploy_argv match" allow "$POLICY" "/abs/deploy --target pine"

# --- clearly non-privileged -----------------------------------------------------------

check "not_privileged: ls" not_privileged "$POLICY" -- ls -la
check "not_privileged: cat file" not_privileged "$POLICY" -- cat somefile.txt

# --- controller audit: config-override / identity / fail-open regressions -----------------------------------------------------------

check "denied: git --config-env override" deny "$POLICY" -- git --config-env=remote.origin.pushurl=EVIL -C "$REPO" push origin
check "unknown_privileged: git unrecognized subcommand (alias/external)" unknown_privileged "$POLICY" -- git -C "$REPO" dangerous-alias
check "not_privileged: git rev-parse remains read-only" not_privileged "$POLICY" -- git -C "$REPO" rev-parse HEAD
check "unknown_privileged: git remote is not on the read-only allowlist" unknown_privileged "$POLICY" -- git -C "$REPO" remote set-url origin http://evil

check "allowed: command-wrapped gh pr merge resolves transparently to the real gh identity" allow "$POLICY" -- command gh pr merge --repo acme/widgets --squash
check "allowed: exec-wrapped gh pr merge resolves transparently to the real gh identity" allow "$POLICY" -- exec gh pr merge --repo acme/widgets --squash
check "denied: command-wrapped gh pr merge still denies when policy denies" deny "$POLICY_DENY" -- command gh pr merge --repo acme/widgets --squash
REAL_GH=$(command -v gh 2>/dev/null || true)
if [ -n "$REAL_GH" ]; then
  check "allowed: installed gh executable path resolves to the same gh identity" allow "$POLICY" -- "$REAL_GH" pr create --repo acme/widgets --title t --body b
fi
check "allowed: absolute path git identity resolves the same as bare git" allow "$POLICY" -- /usr/bin/git -C "$REPO" commit -m msg

# privileged tool identity must not depend on argv[0] basename alone. A byte-identical
# renamed copy is still the Git executable and must be classified as Git; a different
# executable merely named `git` must fail closed rather than inherit Git privileges.
mkdir -p "$WORKROOT/tool-identity"
REAL_GIT=$(command -v git)
cp "$REAL_GIT" "$WORKROOT/tool-identity/gcopy"
chmod +x "$WORKROOT/tool-identity/gcopy"
printf '#!/bin/bash\nexit 0\n' >"$WORKROOT/tool-identity/git"
chmod +x "$WORKROOT/tool-identity/git"
check "denied: renamed byte-identical Git binary cannot bypass force-push policy" deny "$POLICY" -- "$WORKROOT/tool-identity/gcopy" -C "$REPO" push --force origin
check "unknown_privileged: unrelated executable merely named git fails closed" unknown_privileged "$POLICY" -- "$WORKROOT/tool-identity/git" -C "$REPO" push origin
check "unknown_privileged: generic wrapper containing direct git mutation is not treated as unrelated" unknown_privileged "$POLICY" -- timeout 5 git -C "$REPO" push origin

check "unknown_privileged: gh api mutation is not on the read-only allowlist" unknown_privileged "$POLICY" -- gh api -X DELETE repos/acme/widgets/git/refs/heads/main
check "unknown_privileged: gh issue close is not on the read-only allowlist" unknown_privileged "$POLICY" -- gh issue close 1 --repo acme/widgets
check "allowed: gh -R before the subcommand (global option reordering) still resolves pr merge" allow "$POLICY" -- gh -R acme/widgets pr merge 1
check "not_privileged: gh repo view remains read-only" not_privileged "$POLICY" -- gh repo view

check_str "unknown_privileged: quoted assignment value with embedded whitespace must fail closed, not misparse" unknown_privileged "$POLICY" 'X="a b" gh pr merge 1 --repo acme/widgets'
check_str "unknown_privileged: quoted command name must fail closed, not misparse" unknown_privileged "$POLICY" '"gh" pr merge --repo acme/widgets --squash'
check_str "allowed: unquoted simple commands are unaffected by the quote fail-closed rule" allow "$POLICY" "git -C $REPO commit -m msg"
check_str "unknown_privileged: raw generic wrapper around git mutation fails closed" unknown_privileged "$POLICY" "timeout 5 git -C $REPO push origin"

check_str "unknown_privileged: background (&) control syntax must fail closed, not misparse as two segments" unknown_privileged "$POLICY" "ls -la & gh pr merge 1 --repo acme/widgets"
check_str "unknown_privileged: if/then/fi control syntax must fail closed" unknown_privileged "$POLICY" "if true; then gh pr merge 1 --repo acme/widgets; fi"
check_str "allowed: && chained segments are unaffected by the control-syntax fail-closed rule" allow "$POLICY" "git -C $REPO commit -m msg && git -C $REPO commit -m msg2"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl-classify unit tests passed."
else
  echo "Some agentctl-classify unit tests FAILED."
fi
exit "$FAILED"
