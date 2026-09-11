#!/bin/bash
# shellcheck disable=SC2015,SC2329
# SC2015: `check && pass || fail` は本テストの意図通り。
# SC2329: cleanup_all は trap 経由の間接呼び出しのため未使用と誤検知される。
#
# design.md:112,410 (inherited process Git override env): agentctl-classify.sh
# の GIT_DIR/GIT_WORK_TREE/GIT_CONFIG_* env override 検出は、.tool_input.command
# の先頭 assignment word だけでなく hook process 自身が backend プロセスから
# 継承した実 env override も対象にしなければならない。
#
# 証明は 2 段に分ける。
#   1. deny 判定そのもの (env override が乗った状態で本来 allow される git
#      commit が実際に deny されること) は
#      tests/unit/test_agentctl_dispatcher.sh が実 agentctl-policy-dispatcher.sh
#      + 実 git repository を使って既に機械的に証明している。
#   2. この live E2E が追加で証明するのは、実 Claude backend プロセス
#      (tmux respawn-pane 経由で起動される) が agentctl start を起動した
#      プロセス自身の ambient env から GIT_DIR を実際に継承すること
#      (production の env 配線が生きた backend process まで届くという事実)。
#      real Claude に「理由なく git commit を実行しろ」と指示すると、
#      正当な理由の無い破壊的操作として (適切に) 拒否されるため、ここでは
#      副作用の無い読み取り専用コマンドで env 継承だけを確認する。
#
# 実 Claude CLI に認証済み credential が必要なため、claude バイナリが無い/
# 疎通できない環境では gracefully skip する。

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
AGENTCTL="$REPO_ROOT/home/bin/executable_agentctl"

FAILED=0
fail() { echo "❌ $*"; FAILED=1; }
pass() { echo "✅ $*"; }

command -v tmux >/dev/null 2>&1 || { echo "⚠️  tmux not found; skipping env override live E2E"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "⚠️  jq not found; skipping env override live E2E"; exit 0; }
command -v claude >/dev/null 2>&1 || { echo "⚠️  claude CLI not found; skipping env override live E2E"; exit 0; }
timeout 20 claude -p "reply with exactly: ok" >/tmp/agentctl-envoverride-e2e-probe.out 2>&1
if ! grep -qi "ok" /tmp/agentctl-envoverride-e2e-probe.out; then
  echo "⚠️  claude CLI not authenticated/reachable; skipping env override live E2E"
  rm -f /tmp/agentctl-envoverride-e2e-probe.out
  exit 0
fi
rm -f /tmp/agentctl-envoverride-e2e-probe.out

WORKROOT=$(mktemp -d)
export XDG_STATE_HOME="$WORKROOT/state"
export TMUX_TMPDIR="$WORKROOT/tmux"
mkdir -p "$TMUX_TMPDIR"
unset TMUX || true

mkdir -p "$WORKROOT/bin"
REAL_TMUX=$(command -v tmux)
cat >"$WORKROOT/bin/tmux" <<WRAP
#!/bin/bash
exec "$REAL_TMUX" -L agentctl-envoverride-e2e-test "\$@"
WRAP
chmod +x "$WORKROOT/bin/tmux"
export PATH="$WORKROOT/bin:$PATH"

cleanup_all() {
  tmux kill-server >/dev/null 2>&1 || true
  rm -rf "$WORKROOT"
}
trap cleanup_all EXIT

mkdir -p "$WORKROOT/worktree"
REPO="$WORKROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" -c core.hooksPath=/dev/null init -q -b main
git -C "$REPO" config user.email t@e.com
git -C "$REPO" config user.name t
git -C "$REPO" -c core.hooksPath=/dev/null commit -q --allow-empty -m init
GCD=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)

POLICY="$WORKROOT/policy.json"
jq -n --arg gcd "$GCD" '{version:1,permissions:{local_write:true,commit:false,push:false,create_pr:false,merge:false,git_cleanup:false,deploy:false,production_verify:false},scope:{repositories:[{id:"primary",git_common_dir:$gcd,github_repo:"acme/widgets",allowed_worktree_roots:[]}],remotes:[],production_targets:[]}}' >"$POLICY"

# pane 幅による wrap で marker が分断されて grep が一致しなくなるのを避ける
# ため短い値にする (agentctl_logs は capture-pane -J で論理行を再結合するが、
# 表示幅の狭い terminal では長いトークンが複数物理行に折り返され得る)。
GIT_DIR_OVERRIDE="/nonexistent-e2e-gitdir-$$"

# GIT_DIR override は agentctl start を起動するこのプロセス自身の環境に乗せる。
# tmux respawn-pane の `env AGENTCTL_...=... bash -c "$backend_cmd"` はこの
# ambient env をそのまま引き継ぐため、実 Claude backend プロセスにも GIT_DIR が
# そのまま継承される。
RID=$(GIT_DIR="$GIT_DIR_OVERRIDE" AGENTCTL_SENTINEL_SUBMIT_TIMEOUT_SECONDS=45 AGENTCTL_GUARD_SENTINEL_TIMEOUT_SECONDS=60 \
  timeout 150 bash "$AGENTCTL" start --name e2eenvoverride --cwd "$WORKROOT/worktree" --backend claude --policy-file "$POLICY" \
  --mission-stdin <<<"Say hello and then stop, do nothing else." \
  2>"$WORKROOT/start-err")
START_RC=$?

[ "$START_RC" -eq 0 ] && [ -n "$RID" ] && pass "agentctl start (real Claude backend, GIT_DIR inherited in ambient env) publishes a runtime" \
  || fail "agentctl start with real Claude backend failed: rc=$START_RC $(cat "$WORKROOT/start-err" 2>/dev/null)"

sleep 3

# 副作用の無い読み取り専用コマンドで、実 backend process の env に GIT_DIR
# override が実際に継承されているかだけを確認する (deny 判定自体は
# tests/unit/test_agentctl_dispatcher.sh の実 dispatcher スクリプトによる
# 検証に委ねる)。
bash "$AGENTCTL" steer --name e2eenvoverride --runtime-id "$RID" --stdin \
  <<<"Run exactly this read-only command via the Bash tool and report its exact output, then stop: echo GIT_DIR_IS_[\$GIT_DIR]" \
  >/dev/null

ENV_SEEN=0
for _ in $(seq 1 60); do
  PANE_TEXT=$(bash "$AGENTCTL" logs --name e2eenvoverride --lines 300 2>/dev/null || true)
  if echo "$PANE_TEXT" | grep -qF "GIT_DIR_IS_[$GIT_DIR_OVERRIDE]"; then
    ENV_SEEN=1
    break
  fi
  sleep 2
done
[ "$ENV_SEEN" -eq 1 ] && pass "real Claude backend process actually inherits the GIT_DIR override from the agentctl start process's ambient env" \
  || fail "did not observe the inherited GIT_DIR value in the real backend process's environment within the timeout"

bash "$AGENTCTL" stop --name e2eenvoverride --runtime-id "$RID" >/dev/null 2>&1 || true
bash "$AGENTCTL" cleanup --name e2eenvoverride --runtime-id "$RID" >/dev/null 2>&1 || true

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All agentctl env override live E2E tests passed."
else
  echo "Some agentctl env override live E2E tests FAILED."
fi
exit "$FAILED"
