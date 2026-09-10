#!/bin/bash
# shellcheck disable=SC2015,SC2329
# SC2015: `check && pass || fail` は本テストの意図通り。
# SC2329: cleanup_all は trap 経由の間接呼び出しのため未使用と誤検知される。
# gh/gh-poi safety boundary テスト。keeper (agentctl) は Git/PR lifecycle を
# 一切所有しないため、通常の mission lifecycle (start/steer/stop/resume/
# complete/cleanup/doctor) を通しても gh/gh-poi を一度も呼び出してはならない。
# PATH 上に sentinel を書く fake gh/gh-poi を置き、実測でそれを検証する。

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
AGENTCTL="$REPO_ROOT/home/bin/executable_agentctl"

FAILED=0
fail() { echo "❌ $*"; FAILED=1; }
pass() { echo "✅ $*"; }

command -v tmux >/dev/null 2>&1 || { echo "⚠️  tmux not found; skipping gh-poi boundary tests"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "⚠️  jq not found; skipping gh-poi boundary tests"; exit 0; }

WORKROOT=$(mktemp -d)
export XDG_STATE_HOME="$WORKROOT/state"
export TMUX_TMPDIR="$WORKROOT/tmux"
mkdir -p "$TMUX_TMPDIR"
unset TMUX || true

SENTINEL="$WORKROOT/gh-invoked.sentinel"
mkdir -p "$WORKROOT/bin"
REAL_TMUX=$(command -v tmux)
cat >"$WORKROOT/bin/tmux" <<WRAP
#!/bin/bash
exec "$REAL_TMUX" -L agentctl-ghpoi-test "\$@"
WRAP
chmod +x "$WORKROOT/bin/tmux"
for fake in gh gh-poi; do
  cat >"$WORKROOT/bin/$fake" <<WRAP
#!/bin/bash
echo "$fake \$*" >>"$SENTINEL"
exit 1
WRAP
  chmod +x "$WORKROOT/bin/$fake"
done
export PATH="$WORKROOT/bin:$PATH"

cleanup_all() {
  tmux kill-server >/dev/null 2>&1 || true
  rm -rf "$WORKROOT"
}
trap cleanup_all EXIT

REPO_FIXTURE="$WORKROOT/repo"
mkdir -p "$REPO_FIXTURE/.git" "$WORKROOT/worktree"
POLICY="$WORKROOT/policy.json"
cat >"$POLICY" <<JSON
{"schema_version":1,"permissions":{"local_write":true,"commit":false,"push":false,"create_pr":false,"merge":false,"git_cleanup":false,"deploy":false,"production_verify":false},"repository":{"git_common_dir":"$REPO_FIXTURE/.git","github_repo":"acme/widgets","allowed_worktree_roots":["$WORKROOT/worktree"]}}
JSON

NAME="ghpoi1"
RID1=$(bash "$AGENTCTL" start --name "$NAME" --cwd "$WORKROOT/worktree" --backend fake --policy-file "$POLICY" --mission-stdin <<<"mission")
bash "$AGENTCTL" status --name "$NAME" --json >/dev/null
bash "$AGENTCTL" logs --name "$NAME" >/dev/null
echo "steer text" | bash "$AGENTCTL" steer --name "$NAME" --runtime-id "$RID1" --stdin >/dev/null
bash "$AGENTCTL" interrupt --name "$NAME" --runtime-id "$RID1" >/dev/null
bash "$AGENTCTL" doctor --json >/dev/null
bash "$AGENTCTL" stop --name "$NAME" --runtime-id "$RID1" >/dev/null

MANIFEST_PATH="$WORKROOT/state/agentctl/runtimes/$NAME/manifest.json"
RID2=$(bash "$AGENTCTL" resume --name "$NAME" --cwd "$WORKROOT/worktree" --backend fake --from-runtime-id "$RID1")
bash "$AGENTCTL" stop --name "$NAME" --runtime-id "$RID2" >/dev/null
jq '.mission_status = "done"' "$MANIFEST_PATH" >"$MANIFEST_PATH.tmp" && mv "$MANIFEST_PATH.tmp" "$MANIFEST_PATH"
bash "$AGENTCTL" complete --name "$NAME" --runtime-id "$RID2" >/dev/null
bash "$AGENTCTL" cleanup --name "$NAME" --runtime-id "$RID2" >/dev/null

if [ -f "$SENTINEL" ]; then
  fail "gh/gh-poi was invoked during normal mission lifecycle: $(cat "$SENTINEL")"
else
  pass "gh/gh-poi is never invoked across start/status/logs/steer/interrupt/doctor/stop/resume/complete/cleanup"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl gh-poi boundary tests passed."
else
  echo "Some agentctl gh-poi boundary tests FAILED."
fi
exit "$FAILED"
