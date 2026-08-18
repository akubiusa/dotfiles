#!/bin/bash
# Discord 通知スクリプトのユニットテスト

set -euo pipefail

echo "Testing Discord notification scripts..."

FAILED=0

# テスト対象の通知スクリプト
NOTIFICATION_SCRIPTS=(
  "home/dot_claude/scripts/completion-notify/executable_send-discord-notification.sh"
  "home/dot_claude/scripts/completion-notify/executable_notify-completion.sh"
  "home/dot_claude/scripts/completion-notify/executable_notify-notification.sh"
  "home/dot_claude/scripts/completion-notify/executable_notify-permission-request.sh"
  "home/dot_claude/scripts/completion-notify/executable_notify-user-prompt-submit.sh"
  "home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
  "home/dot_codex/scripts/completion-notify/executable_send-discord-notification.sh"
  "home/dot_codex/scripts/completion-notify/executable_notify-completion.sh"
  "home/dot_codex/scripts/completion-notify/executable_notify-permission-request.sh"
  "home/dot_codex/scripts/completion-notify/executable_notify-user-prompt-submit.sh"
  "home/dot_codex/scripts/completion-notify/executable_notify-post-tool-use.sh"
)

# 各通知スクリプトの構文チェック
for script in "${NOTIFICATION_SCRIPTS[@]}"; do
  if [ ! -f "$script" ]; then
    echo "⚠️  Notification script not found: $script"
    continue
  fi

  echo "Testing script: $script"

  # bash 構文チェック
  if ! bash -n "$script"; then
    echo "❌ Syntax error in script: $script"
    FAILED=1
  else
    echo "✅ Syntax OK: $script"
  fi
done

echo "Testing Codex completion hook returns valid Stop-hook JSON..."
TEST_HOME=$(mktemp -d)
COMPLETION_OUTPUT=$(HOME="$TEST_HOME" bash home/dot_codex/scripts/completion-notify/executable_notify-completion.sh <<'EOF'
{"session_id":"test-session","cwd":"/tmp/test","last_assistant_message":"done"}
EOF
)
if [[ "$COMPLETION_OUTPUT" != "{}" ]]; then
  echo "❌ Codex completion hook did not return an empty JSON object (got: $COMPLETION_OUTPUT)"
  FAILED=1
else
  echo "✅ Codex completion hook returned valid Stop-hook JSON"
fi
if grep -Fq 'tool_input' home/dot_codex/scripts/completion-notify/executable_notify-permission-request.sh; then
  echo "❌ Codex permission notification must not include tool input"
  FAILED=1
else
  echo "✅ Codex permission notification excludes tool input"
fi
rm -rf "$TEST_HOME"

echo "Testing Claude Code built-in usage-limit auto-continue is enabled..."
if jq -e '.autoContinueAtUsageLimit == true' home/dot_claude/private_settings.json >/dev/null; then
  echo "✅ Claude Code built-in usage-limit auto-continue is enabled"
else
  echo "❌ autoContinueAtUsageLimit must be true in Claude settings"
  FAILED=1
fi

echo "Testing legacy Claude limit-unlocked implementation is removed..."
if [ -e home/dot_claude/scripts/limit-unlocked ]; then
  echo "❌ Legacy Claude limit-unlocked implementation still exists"
  FAILED=1
else
  echo "✅ Legacy Claude limit-unlocked implementation is removed"
fi

echo "Testing Codex check-notify.sh is safely sourceable (no side effects)..."
TEST_HOME=$(mktemp -d)
if ! (
  HOME="$TEST_HOME" bash -c '
    source "'"$PWD"'/home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
    if declare -p STATE_FILE >/dev/null 2>&1; then
      echo "STATE_FILE should not be set when sourced" >&2
      exit 1
    fi
    if ! declare -F resolve_rollout_path >/dev/null 2>&1; then
      echo "resolve_rollout_path should be defined after sourcing" >&2
      exit 1
    fi
  '
); then
  echo "❌ Codex check-notify.sh executed main logic (or failed) when sourced"
  FAILED=1
else
  echo "✅ Codex check-notify.sh only defines functions when sourced"
fi
if [ -d "$TEST_HOME/.codex/scripts/limit-unlocked/data" ]; then
  echo "❌ Codex check-notify.sh created state directory as a side effect of sourcing"
  FAILED=1
fi
rm -rf "$TEST_HOME"

echo "Testing Codex check_limit_status parses a usage_limit_exceeded task_complete with a token_count resets_at..."
TEST_HOME=$(mktemp -d)
FIXTURE_JSONL="$TEST_HOME/fixture-rollout.jsonl"
cat > "$FIXTURE_JSONL" <<'EOF'
{"timestamp":"2026-08-02T11:47:20.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":100.0,"window_minutes":10080,"resets_at":1786165193},"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":"plus","rate_limit_reached_type":null}}}
{"timestamp":"2026-08-02T11:47:24.660Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":null,"error":{"message":"You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Aug 8th, 2026 1:59 PM.","codex_error_info":"usage_limit_exceeded"},"started_at":1785671243,"completed_at":1785671244,"duration_ms":1410}}
EOF

RESULT=$(
  bash -c '
    source "'"$PWD"'/home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
    check_limit_status "'"$FIXTURE_JSONL"'"
  '
)
IFS=$'\t' read -r is_limited reset_epoch reset_text <<< "$RESULT"

if [[ "$is_limited" != "1" ]]; then
  echo "❌ check_limit_status did not detect a usage_limit_exceeded task_complete (got: '$RESULT')"
  FAILED=1
else
  echo "✅ check_limit_status detected a usage_limit_exceeded task_complete"
fi

if [[ "$reset_epoch" != "1786165193" ]]; then
  echo "❌ check_limit_status did not use the token_count rate_limits.primary.resets_at epoch (got: '$reset_epoch')"
  FAILED=1
else
  echo "✅ check_limit_status used the token_count rate_limits.primary.resets_at epoch"
fi

if [[ "$reset_text" != *"usage limit"* ]]; then
  echo "❌ check_limit_status did not carry through the error message text (got: '$reset_text')"
  FAILED=1
else
  echo "✅ check_limit_status carried through the error message text"
fi

echo "Testing Codex check_limit_status treats error:null task_complete as not limited..."
FIXTURE_JSONL_OK="$TEST_HOME/fixture-rollout-ok.jsonl"
cat > "$FIXTURE_JSONL_OK" <<'EOF'
{"timestamp":"2026-08-02T11:50:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t2","last_agent_message":"done","error":null,"started_at":1785671300,"completed_at":1785671301,"duration_ms":900}}
EOF

RESULT_OK=$(
  bash -c '
    source "'"$PWD"'/home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
    check_limit_status "'"$FIXTURE_JSONL_OK"'"
  '
)

if [[ "$RESULT_OK" != $'0\t-\t-' ]]; then
  echo "❌ check_limit_status incorrectly reported a limited state for an error:null task_complete (got: '$RESULT_OK')"
  FAILED=1
else
  echo "✅ check_limit_status correctly reported not-limited for an error:null task_complete"
fi

echo "Testing Codex check_limit_status clears a stale usage_limit_exceeded state after a later below-cap token_count..."
FIXTURE_JSONL_STALE_LIMIT="$TEST_HOME/fixture-rollout-stale-limit.jsonl"
cat > "$FIXTURE_JSONL_STALE_LIMIT" <<'EOF'
{"timestamp":"2026-08-02T11:47:24.660Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":null,"error":{"message":"usage limit hit","codex_error_info":"usage_limit_exceeded"},"started_at":1785671243,"completed_at":1785671244,"duration_ms":1410}}
{"timestamp":"2026-08-08T05:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"primary":{"used_percent":1.0,"window_minutes":300,"resets_at":1786168800},"secondary":null}}}
EOF

RESULT_STALE_LIMIT=$(
  bash -c '
    source "'"$PWD"'/home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
    check_limit_status "'"$FIXTURE_JSONL_STALE_LIMIT"'"
  '
)

if [[ "$RESULT_STALE_LIMIT" != $'0\t-\t-' ]]; then
  echo "❌ check_limit_status did not clear a stale usage_limit_exceeded state (got: '$RESULT_STALE_LIMIT')"
  FAILED=1
else
  echo "✅ check_limit_status cleared a stale usage_limit_exceeded state"
fi

rm -rf "$TEST_HOME"

echo "Testing Codex resolve_rollout_path discovers the rollout jsonl via /proc fd scan and picks the newest mtime..."
TEST_HOME=$(mktemp -d)
TEST_HOME=$(readlink -f "$TEST_HOME") # /proc/<pid>/fd の readlink -f 結果と文字列比較できるよう正規化する
TEST_BIN_DIR=$(mktemp -d)
mkdir -p "$TEST_HOME/.codex/sessions/2026/08/02"

OLD_ROLLOUT="$TEST_HOME/.codex/sessions/2026/08/02/rollout-1785660000-old.jsonl"
NEW_ROLLOUT="$TEST_HOME/.codex/sessions/2026/08/02/rollout-1785671200-new.jsonl"
echo '{}' > "$OLD_ROLLOUT"
touch -d "-1 hour" "$OLD_ROLLOUT"
echo '{}' > "$NEW_ROLLOUT"

# 実際に fd を開いたまま維持するバックグラウンドプロセスを立て、fd スキャンが
# 実プロセスの /proc/<pid>/fd を正しく辿れることを end-to-end で検証する
# (同一 pid が複数の rollout fd を開いたままにする、という実運用のケースを再現する)。
# 新しい方の rollout を若い fd 番号(3)に、古い方を後の fd 番号(4)に割り当てることで、
# /proc/<pid>/fd の走査順(数字の小さい順)と mtime の新旧が逆になるようにし、
# 「単に最後に見つかったものを採用する」実装ではこのテストを通せないようにする
bash -c "exec 3<'$NEW_ROLLOUT' 4<'$OLD_ROLLOUT'; sleep 60" &
FAKE_CODEX_PID=$!
sleep 0.2

cat > "$TEST_BIN_DIR/tmux" <<EOF
#!/bin/bash
if [[ "\$1" == "display-message" ]]; then
  echo "$FAKE_CODEX_PID"
  exit 0
fi
exit 1
EOF
chmod +x "$TEST_BIN_DIR/tmux"

RESULT=$(
  PATH="$TEST_BIN_DIR:$PATH" HOME="$TEST_HOME" bash -c '
    source "'"$PWD"'/home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
    resolve_rollout_path "dummy-session"
  '
)

kill "$FAKE_CODEX_PID" 2>/dev/null || true
wait "$FAKE_CODEX_PID" 2>/dev/null || true

if [[ "$RESULT" != "$NEW_ROLLOUT" ]]; then
  echo "❌ resolve_rollout_path did not pick the rollout jsonl with the newest mtime via /proc fd scan (got: '$RESULT', want: '$NEW_ROLLOUT')"
  FAILED=1
else
  echo "✅ resolve_rollout_path discovered the rollout jsonl via /proc fd scan and picked the newest mtime"
fi

rm -rf "$TEST_HOME" "$TEST_BIN_DIR"

echo "Testing Codex resolve_rollout_path prefers the root session rollout over a newer subagent rollout..."
TEST_HOME=$(mktemp -d)
TEST_HOME=$(readlink -f "$TEST_HOME")
TEST_BIN_DIR=$(mktemp -d)
mkdir -p "$TEST_HOME/.codex/sessions/2026/08/02"

ROOT_ROLLOUT="$TEST_HOME/.codex/sessions/2026/08/02/rollout-root.jsonl"
SUBAGENT_ROLLOUT="$TEST_HOME/.codex/sessions/2026/08/02/rollout-subagent.jsonl"
printf '%s\n' '{"type":"session_meta","payload":{"id":"root","session_id":"root","source":"cli","thread_source":"user"}}' > "$ROOT_ROLLOUT"
touch -d "-1 minute" "$ROOT_ROLLOUT"
printf '%s\n' '{"type":"session_meta","payload":{"id":"subagent","session_id":"root","source":{"subagent":{}},"thread_source":"subagent"}}' > "$SUBAGENT_ROLLOUT"

bash -c "exec 3<'$SUBAGENT_ROLLOUT' 4<'$ROOT_ROLLOUT'; sleep 60" &
FAKE_CODEX_PID=$!
sleep 0.2

cat > "$TEST_BIN_DIR/tmux" <<EOF
#!/bin/bash
if [[ "\$1" == "display-message" ]]; then
  echo "$FAKE_CODEX_PID"
  exit 0
fi
exit 1
EOF
chmod +x "$TEST_BIN_DIR/tmux"

RESULT_ROOT=$(
  PATH="$TEST_BIN_DIR:$PATH" HOME="$TEST_HOME" bash -c '
    source "'"$PWD"'/home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
    resolve_rollout_path "dummy-session"
  '
)

kill "$FAKE_CODEX_PID" 2>/dev/null || true
wait "$FAKE_CODEX_PID" 2>/dev/null || true

if [[ "$RESULT_ROOT" != "$ROOT_ROLLOUT" ]]; then
  echo "❌ resolve_rollout_path preferred a newer subagent rollout over the root session rollout (got: '$RESULT_ROOT', want: '$ROOT_ROLLOUT')"
  FAILED=1
else
  echo "✅ resolve_rollout_path preferred the root session rollout over a newer subagent rollout"
fi

rm -rf "$TEST_HOME" "$TEST_BIN_DIR"

echo "Testing Codex check_limit_status reports status=2 (undetermined) when jq fails to parse the scanned window..."
TEST_HOME=$(mktemp -d)
FIXTURE_JSONL_BROKEN="$TEST_HOME/fixture-rollout-broken.jsonl"
printf '{not valid json\n' > "$FIXTURE_JSONL_BROKEN"

RESULT_BROKEN=$(
  bash -c '
    source "'"$PWD"'/home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
    check_limit_status "'"$FIXTURE_JSONL_BROKEN"'"
  '
)

if [[ "$RESULT_BROKEN" != $'2\t-\t-' ]]; then
  echo "❌ check_limit_status did not report status=2 for an unparseable jsonl window (got: '$RESULT_BROKEN')"
  FAILED=1
else
  echo "✅ check_limit_status reported status=2 (undetermined) instead of silently treating a parse failure as not-limited"
fi
rm -rf "$TEST_HOME"

echo "Testing Codex check_limit_status prefers the rate-limit window actually at 100% used_percent over an unconditional primary preference..."
TEST_HOME=$(mktemp -d)
FIXTURE_JSONL_SECONDARY="$TEST_HOME/fixture-rollout-secondary.jsonl"
cat > "$FIXTURE_JSONL_SECONDARY" <<'EOF'
{"timestamp":"2026-08-02T11:47:20.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":40.0,"window_minutes":300,"resets_at":1111111111},"secondary":{"used_percent":100.0,"window_minutes":10080,"resets_at":2222222222},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":"plus","rate_limit_reached_type":null}}}
{"timestamp":"2026-08-02T11:47:24.660Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":null,"error":{"message":"usage limit hit","codex_error_info":"usage_limit_exceeded"},"started_at":1785671243,"completed_at":1785671244,"duration_ms":1410}}
EOF

RESULT_SECONDARY=$(
  bash -c '
    source "'"$PWD"'/home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
    check_limit_status "'"$FIXTURE_JSONL_SECONDARY"'"
  '
)
IFS=$'\t' read -r _ reset_epoch_secondary _ <<< "$RESULT_SECONDARY"

if [[ "$reset_epoch_secondary" != "2222222222" ]]; then
  echo "❌ check_limit_status did not prefer the secondary window's resets_at even though only secondary is at 100% used_percent (got: '$reset_epoch_secondary')"
  FAILED=1
else
  echo "✅ check_limit_status preferred the at-cap secondary window's resets_at over an unconditional primary preference"
fi
rm -rf "$TEST_HOME"

echo "Testing Codex goal_resume_required fails safely when the rollout window contains malformed JSON..."
TEST_HOME=$(mktemp -d)
FIXTURE_JSONL_GOAL_PARSE_ERROR="$TEST_HOME/fixture-rollout-goal-parse-error.jsonl"
cat > "$FIXTURE_JSONL_GOAL_PARSE_ERROR" <<'EOF'
{"timestamp":"2026-08-08T05:00:00.000Z","type":"event_msg","payload":{"type":"thread_goal_updated","threadId":"thread-1","goal":{"threadId":"thread-1","objective":"finish the task","status":"usageLimited","tokensUsed":100,"timeUsedSeconds":60,"createdAt":1,"updatedAt":2}}}
{not-json
EOF

RESULT_GOAL_PARSE_ERROR=$(
  HOME="$TEST_HOME" bash -c '
    source "'"$PWD"'/home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
    if goal_resume_required "'"$FIXTURE_JSONL_GOAL_PARSE_ERROR"'"; then
      printf "%s\n" required
    else
      printf "%s\n" not-required
    fi
  '
)
if [[ "$RESULT_GOAL_PARSE_ERROR" != "not-required" ]]; then
  echo "❌ goal_resume_required treated a malformed rollout as safely resumable (got: '$RESULT_GOAL_PARSE_ERROR')"
  FAILED=1
else
  echo "✅ goal_resume_required failed safely on malformed rollout JSON"
fi
rm -rf "$TEST_HOME"

echo "Testing Codex resume_session keeps the generic resume message for a non-goal session..."
TEST_HOME=$(mktemp -d)
FIXTURE_JSONL_NON_GOAL="$TEST_HOME/fixture-rollout-non-goal.jsonl"
cat > "$FIXTURE_JSONL_NON_GOAL" <<'EOF'
{"timestamp":"2026-08-08T05:00:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":null,"error":{"message":"usage limit hit","codex_error_info":"usage_limit_exceeded"},"started_at":1,"completed_at":2,"duration_ms":1000}}
EOF

RESULT_NON_GOAL_RESUME=$(
  HOME="$TEST_HOME" bash -c '
    source "'"$PWD"'/home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
    resolve_rollout_path() { printf "%s\n" "'"$FIXTURE_JSONL_NON_GOAL"'"; }
    sleep() { :; }
    tmux() { printf "%s\n" "$*"; }
    resume_session "sess-1"
  '
)
EXPECTED_NON_GOAL_RESUME="send-keys -t sess-1: <system-reminder>Codex's rate limit has been lifted. Continue the task you were working on before the interruption.</system-reminder>"
EXPECTED_NON_GOAL_RESUME="${EXPECTED_NON_GOAL_RESUME}"$'\n'"send-keys -t sess-1: Enter"
if [[ "$RESULT_NON_GOAL_RESUME" != "$EXPECTED_NON_GOAL_RESUME" ]]; then
  echo "❌ resume_session changed the non-goal resume input unexpectedly (got: '$RESULT_NON_GOAL_RESUME')"
  FAILED=1
else
  echo "✅ resume_session kept the generic resume message for a non-goal session"
fi
rm -rf "$TEST_HOME"

echo "Testing Codex resume_session sends /goal resume when the current goal is usage limited..."
TEST_HOME=$(mktemp -d)
FIXTURE_JSONL_GOAL_LIMITED="$TEST_HOME/fixture-rollout-goal-limited.jsonl"
cat > "$FIXTURE_JSONL_GOAL_LIMITED" <<'EOF'
{"timestamp":"2026-08-08T05:00:00.000Z","type":"event_msg","payload":{"type":"thread_goal_updated","threadId":"thread-1","goal":{"threadId":"thread-1","objective":"finish the task","status":"usageLimited","tokensUsed":100,"timeUsedSeconds":60,"createdAt":1,"updatedAt":2}}}
EOF

RESULT_GOAL_RESUME=$(
  HOME="$TEST_HOME" bash -c '
    source "'"$PWD"'/home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
    resolve_rollout_path() { printf "%s\n" "'"$FIXTURE_JSONL_GOAL_LIMITED"'"; }
    sleep() { :; }
    tmux() { printf "%s\n" "$*"; }
    resume_session "sess-1"
  '
)
EXPECTED_GOAL_RESUME=$'send-keys -t sess-1: /goal resume\nsend-keys -t sess-1: Enter'
if [[ "$RESULT_GOAL_RESUME" != "$EXPECTED_GOAL_RESUME" ]]; then
  echo "❌ resume_session did not use /goal resume for a usage-limited goal (got: '$RESULT_GOAL_RESUME')"
  FAILED=1
else
  echo "✅ resume_session used /goal resume for a usage-limited goal"
fi
rm -rf "$TEST_HOME"

echo "Testing Codex already_resumed_for / record_resumed_for dedup resume_session for the same reset_epoch..."
TEST_HOME=$(mktemp -d)
RESULT_RESUME_DEDUP=$(
  HOME="$TEST_HOME" bash -c '
    source "'"$PWD"'/home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
    already_resumed_for "sess-1" "1700000000" && echo "unexpected-already-resumed"
    record_resumed_for "sess-1" "1700000000"
    already_resumed_for "sess-1" "1700000000" && echo "resumed-for-same-epoch"
    already_resumed_for "sess-1" "1700000001" || echo "not-resumed-for-different-epoch"
  '
)
if [[ "$RESULT_RESUME_DEDUP" != $'resumed-for-same-epoch\nnot-resumed-for-different-epoch' ]]; then
  echo "❌ already_resumed_for/record_resumed_for did not correctly dedup resume attempts per reset_epoch (got: '$RESULT_RESUME_DEDUP')"
  FAILED=1
else
  echo "✅ already_resumed_for/record_resumed_for correctly dedup resume attempts keyed by reset_epoch"
fi
rm -rf "$TEST_HOME"

echo "Testing Codex already_notified_for / record_notified_for dedup Discord notifications for the same reset_epoch..."
TEST_HOME=$(mktemp -d)
RESULT_NOTIFY_DEDUP=$(
  HOME="$TEST_HOME" bash -c '
    source "'"$PWD"'/home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
    already_notified_for "sess-1" "1700000000" && echo "unexpected-already-notified"
    record_notified_for "sess-1" "1700000000"
    already_notified_for "sess-1" "1700000000" && echo "notified-for-same-epoch"
    already_notified_for "sess-1" "1700000001" || echo "not-notified-for-different-epoch"
  '
)
if [[ "$RESULT_NOTIFY_DEDUP" != $'notified-for-same-epoch\nnot-notified-for-different-epoch' ]]; then
  echo "❌ already_notified_for/record_notified_for did not correctly dedup notifications per reset_epoch (got: '$RESULT_NOTIFY_DEDUP')"
  FAILED=1
else
  echo "✅ already_notified_for/record_notified_for correctly dedup notifications keyed by reset_epoch"
fi
rm -rf "$TEST_HOME"

echo "Testing Codex send_discord returns failure on a non-2xx HTTP response instead of silently swallowing it..."
TEST_BIN_DIR=$(mktemp -d)
cat > "$TEST_BIN_DIR/curl" <<'EOF'
#!/bin/bash
echo -n "500"
EOF
chmod +x "$TEST_BIN_DIR/curl"

if PATH="$TEST_BIN_DIR:$PATH" bash -c '
  source "'"$PWD"'/home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
  DISCORD_WEBHOOK_URL="https://example.invalid/webhook"
  send_discord "title" "description" 123
' 2>/dev/null; then
  echo "❌ send_discord did not report failure for a non-2xx Discord HTTP response"
  FAILED=1
else
  echo "✅ send_discord reported failure for a non-2xx Discord HTTP response"
fi
rm -rf "$TEST_BIN_DIR"

echo "Testing Codex carry_forward_previous_entry drops a session after enough consecutive resolve failures instead of preserving it forever..."
TEST_HOME=$(mktemp -d)
STATE_FILE_STALE="$TEST_HOME/limited_sessions.txt"
NEW_STATE_FILE_STALE="${STATE_FILE_STALE}.new"
printf 'stale-sess\t/tmp/proj\t1111111111\tsome text\t1\n' > "$STATE_FILE_STALE"
: > "$NEW_STATE_FILE_STALE"

RESULT_STALE=$(
  HOME="$TEST_HOME" STATE_FILE="$STATE_FILE_STALE" NEW_STATE_FILE="$NEW_STATE_FILE_STALE" bash -c '
    source "'"$PWD"'/home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
    for _ in $(seq 1 12); do
      : > "$NEW_STATE_FILE"
      carry_forward_previous_entry "stale-sess"
    done
    cat "$NEW_STATE_FILE"
  '
)

if [[ -n "$RESULT_STALE" ]]; then
  echo "❌ carry_forward_previous_entry kept carrying a session forward past the consecutive-failure threshold (got: '$RESULT_STALE')"
  FAILED=1
else
  echo "✅ carry_forward_previous_entry stopped carrying a session forward after the consecutive-failure threshold was reached"
fi
rm -rf "$TEST_HOME"

echo "Testing Codex detect_limited_sessions preserves STATE_FILE when tmux list-sessions itself fails..."
TEST_HOME=$(mktemp -d)
TEST_BIN_DIR=$(mktemp -d)
STATE_FILE_ENUM_FAIL="$TEST_HOME/limited_sessions.txt"
NEW_STATE_FILE_ENUM_FAIL="${STATE_FILE_ENUM_FAIL}.new"
printf 'tracked-sess\t/tmp/proj\t1111111111\tsome text\t1\n' > "$STATE_FILE_ENUM_FAIL"

cat > "$TEST_BIN_DIR/tmux" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$TEST_BIN_DIR/tmux"

if PATH="$TEST_BIN_DIR:$PATH" HOME="$TEST_HOME" STATE_FILE="$STATE_FILE_ENUM_FAIL" NEW_STATE_FILE="$NEW_STATE_FILE_ENUM_FAIL" bash -c '
  source "'"$PWD"'/home/dot_codex/scripts/limit-unlocked/executable_check-notify.sh"
  detect_limited_sessions
'; then
  echo "❌ detect_limited_sessions did not report failure when tmux list-sessions failed with existing tracked state"
  FAILED=1
else
  echo "✅ detect_limited_sessions reported failure instead of silently wiping tracked state when tmux list-sessions failed"
fi
rm -rf "$TEST_HOME" "$TEST_BIN_DIR"

if [ $FAILED -eq 0 ]; then
  echo "✅ All notification script tests passed"
else
  echo "❌ Some notification script tests failed"
  exit 1
fi
