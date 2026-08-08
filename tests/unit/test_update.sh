#!/bin/bash
# update.sh のユニットテスト
set -euo pipefail

SCRIPT="$(pwd)/update.sh"

make_fake_curl() {
  local bin_dir="$1"
  cat > "$bin_dir/curl" <<'EOF'
#!/bin/bash
printf 'curl\n' >> "$HOME/curl-invocation"
if [[ -n "${FAKE_CURL_SLEEP:-}" ]]; then
  sleep "$FAKE_CURL_SLEEP"
fi
if [[ "${FAKE_CURL_FAIL:-0}" == "1" ]]; then
  exit 22
fi
cat <<'INSTALLER'
#!/bin/sh
bindir="$PWD/bin"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -b) bindir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$bindir"
cat > "$bindir/chezmoi" <<'CHEZMOI'
#!/bin/bash
printf '%s\n' "$*" > "$HOME/chezmoi-invocation"
exit "${FAKE_CHEZMOI_EXIT:-0}"
CHEZMOI
chmod +x "$bindir/chezmoi"
INSTALLER
EOF
  chmod +x "$bin_dir/curl"
}

run_update() {
  local home="$1"
  local bin_dir="$2"
  HOME="$home" PATH="$bin_dir:/usr/bin:/bin" bash "$SCRIPT" "${@:3}"
}

echo "Testing update.sh canonical chezmoi path..."
TEST_HOME=$(mktemp -d)
TEST_BIN=$(mktemp -d)
make_fake_curl "$TEST_BIN"
mkdir -p "$TEST_HOME/bin"
printf '#!/bin/bash\nexit 0\n' > "$TEST_HOME/bin/chezmoi"
chmod +x "$TEST_HOME/bin/chezmoi"
run_update "$TEST_HOME" "$TEST_BIN"
[[ -x "$TEST_HOME/.local/bin/chezmoi" ]] || { echo "❌ update.sh did not install chezmoi to ~/.local/bin"; exit 1; }
[[ ! -e "$TEST_HOME/bin/chezmoi" ]] || { echo "❌ update.sh did not remove the legacy ~/bin/chezmoi"; exit 1; }
[[ "$(cat "$TEST_HOME/chezmoi-invocation")" == "update" ]] || { echo "❌ update.sh did not invoke the canonical chezmoi binary with update"; exit 1; }
[[ -f "$TEST_HOME/.cache/chezmoi-update/last-update" ]] || { echo "❌ update.sh did not record successful update"; exit 1; }
rm -rf "$TEST_HOME" "$TEST_BIN"
echo "✅ canonical chezmoi path test passed"

echo "Testing update.sh curl failure propagation..."
TEST_HOME=$(mktemp -d)
TEST_BIN=$(mktemp -d)
make_fake_curl "$TEST_BIN"
set +e
FAKE_CURL_FAIL=1 run_update "$TEST_HOME" "$TEST_BIN"
RC=$?
set -e
[[ $RC -ne 0 ]] || { echo "❌ update.sh returned success after curl failure"; exit 1; }
[[ ! -f "$TEST_HOME/.cache/chezmoi-update/last-update" ]] || { echo "❌ update.sh recorded success after curl failure"; exit 1; }
rm -rf "$TEST_HOME" "$TEST_BIN"
echo "✅ curl failure propagation test passed"

echo "Testing update.sh chezmoi failure propagation..."
TEST_HOME=$(mktemp -d)
TEST_BIN=$(mktemp -d)
make_fake_curl "$TEST_BIN"
set +e
FAKE_CHEZMOI_EXIT=42 run_update "$TEST_HOME" "$TEST_BIN"
RC=$?
set -e
[[ $RC -eq 42 ]] || { echo "❌ update.sh did not return chezmoi exit code (got $RC)"; exit 1; }
[[ ! -f "$TEST_HOME/.cache/chezmoi-update/last-update" ]] || { echo "❌ update.sh recorded success after chezmoi failure"; exit 1; }
rm -rf "$TEST_HOME" "$TEST_BIN"
echo "✅ chezmoi failure propagation test passed"


echo "Testing update.sh --force bypasses the 24-hour throttle..."
TEST_HOME=$(mktemp -d)
TEST_BIN=$(mktemp -d)
make_fake_curl "$TEST_BIN"
mkdir -p "$TEST_HOME/.cache/chezmoi-update"
date +%s > "$TEST_HOME/.cache/chezmoi-update/last-update"
run_update "$TEST_HOME" "$TEST_BIN" --force
[[ "$(wc -l < "$TEST_HOME/curl-invocation" | tr -d ' ')" == "1" ]] || { echo "❌ --force did not run an update"; exit 1; }
[[ "$(cat "$TEST_HOME/chezmoi-invocation")" == "update" ]] || { echo "❌ --force did not invoke chezmoi update"; exit 1; }
rm -rf "$TEST_HOME" "$TEST_BIN"
echo "✅ --force bypass test passed"

echo "Testing update.sh serializes concurrent updates..."
TEST_HOME=$(mktemp -d)
TEST_BIN=$(mktemp -d)
make_fake_curl "$TEST_BIN"
FAKE_CURL_SLEEP=1 run_update "$TEST_HOME" "$TEST_BIN" &
FIRST_PID=$!
for _ in $(seq 1 50); do
  [[ -f "$TEST_HOME/curl-invocation" ]] && break
  sleep 0.02
done
run_update "$TEST_HOME" "$TEST_BIN"
wait "$FIRST_PID"
[[ "$(wc -l < "$TEST_HOME/curl-invocation" | tr -d ' ')" == "1" ]] || { echo "❌ concurrent updates were not serialized"; exit 1; }
rm -rf "$TEST_HOME" "$TEST_BIN"
echo "✅ concurrent update serialization test passed"

echo "Testing systemd timer deployment contract..."
SERVICE="home/dot_config/systemd/user/chezmoi-update.service"
TIMER="home/dot_config/systemd/user/chezmoi-update.timer"
ENABLE_LINK="home/dot_config/systemd/user/timers.target.wants/symlink_chezmoi-update.timer"
RELOAD_SCRIPT="home/run_onchange_after_20-reload-chezmoi-update-timer.sh.tmpl"
[[ -f "$SERVICE" ]] || { echo "❌ systemd service is missing"; exit 1; }
[[ -f "$TIMER" ]] || { echo "❌ systemd timer is missing"; exit 1; }
[[ -f "$ENABLE_LINK" ]] || { echo "❌ timer enable symlink source is missing"; exit 1; }
[[ -f "$RELOAD_SCRIPT" ]] || { echo "❌ timer reload script is missing"; exit 1; }
grep -Fq 'ExecStart=%h/.local/share/chezmoi/update.sh --force' "$SERVICE" || { echo "❌ service does not force the scheduled update"; exit 1; }
grep -Fq 'OnCalendar=daily' "$TIMER" || { echo "❌ timer is not daily"; exit 1; }
grep -Fq 'Persistent=true' "$TIMER" || { echo "❌ timer is not persistent"; exit 1; }
[[ "$(cat "$ENABLE_LINK")" == "../chezmoi-update.timer" ]] || { echo "❌ timer enable symlink target is incorrect"; exit 1; }
grep -Fq 'systemctl --user daemon-reload' "$RELOAD_SCRIPT" || { echo "❌ reload script does not reload the user manager"; exit 1; }
grep -Fq 'systemctl --user start chezmoi-update.timer' "$RELOAD_SCRIPT" || { echo "❌ reload script does not start the timer"; exit 1; }
echo "✅ systemd timer deployment contract passed"


echo "Testing timer reload script skips start when the unit is not visible to the user manager..."
TEST_BIN=$(mktemp -d)
START_MARKER=$(mktemp)
rm -f "$START_MARKER"
cat > "$TEST_BIN/systemctl" <<EOF
#!/bin/bash
case "\$*" in
  "--user show-environment"|"--user daemon-reload") exit 0 ;;
  "--user cat chezmoi-update.timer") exit 1 ;;
  "--user start chezmoi-update.timer") touch "$START_MARKER"; exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_BIN/systemctl"
RENDERED_RELOAD_SCRIPT=$(mktemp)
sed '1d;$d' "$RELOAD_SCRIPT" > "$RENDERED_RELOAD_SCRIPT"
PATH="$TEST_BIN:/usr/bin:/bin" bash "$RENDERED_RELOAD_SCRIPT"
[[ ! -e "$START_MARKER" ]] || { echo "❌ reload script tried to start a timer that the user manager cannot see"; exit 1; }
rm -rf "$TEST_BIN" "$START_MARKER" "$RENDERED_RELOAD_SCRIPT"
echo "✅ invisible timer unit is skipped safely"
