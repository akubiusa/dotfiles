#!/bin/bash
# powerline-daemon-launch.sh のユニットテスト
#
# 実際の python3-powerline パッケージの有無に依存せず、
# native/compat 分岐ロジックのみを fake バイナリで検証する。

set -euo pipefail

echo "Testing powerline-daemon-launch.sh..."

FAILED=0
SCRIPT="home/bin/executable_powerline-daemon-launch.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "❌ Script not found: $SCRIPT"
  exit 1
fi

bash -n "$SCRIPT" || { echo "❌ Syntax error: $SCRIPT"; exit 1; }

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# 1. native (get_argparser 呼び出し成功) の場合、native daemon をそのまま exec する
cat > "$TEST_DIR/python3-ok.sh" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-c" ]]; then
  exit 0
fi
echo "COMPAT_INVOKED $*"
EOF
cat > "$TEST_DIR/daemon.sh" <<'EOF'
#!/bin/bash
echo "NATIVE_INVOKED $*"
EOF
chmod +x "$TEST_DIR/python3-ok.sh" "$TEST_DIR/daemon.sh"

OUTPUT=$(POWERLINE_DAEMON_LAUNCH_PYTHON3="$TEST_DIR/python3-ok.sh" \
  POWERLINE_DAEMON_LAUNCH_DAEMON="$TEST_DIR/daemon.sh" \
  bash "$SCRIPT" -q)
if [[ "$OUTPUT" == "NATIVE_INVOKED -q" ]]; then
  echo "✅ native daemon が動作可能な場合、native をそのまま exec する"
else
  echo "❌ native 分岐が期待通りに動作しなかった: $OUTPUT"
  FAILED=1
fi

# 2. native (get_argparser 呼び出し失敗) の場合、compat fallback を実行する
cat > "$TEST_DIR/python3-broken.sh" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-c" ]]; then
  exit 1
fi
echo "COMPAT_INVOKED $*"
EOF
chmod +x "$TEST_DIR/python3-broken.sh"

OUTPUT=$(POWERLINE_DAEMON_LAUNCH_PYTHON3="$TEST_DIR/python3-broken.sh" \
  POWERLINE_DAEMON_LAUNCH_DAEMON="$TEST_DIR/daemon.sh" \
  bash "$SCRIPT" -q)
if [[ "$OUTPUT" == "COMPAT_INVOKED - -q" ]]; then
  echo "✅ native daemon が動作不可の場合、compat fallback を実行する"
else
  echo "❌ compat 分岐が期待通りに動作しなかった: $OUTPUT"
  FAILED=1
fi

exit $FAILED
