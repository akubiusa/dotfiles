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
printf '%s\n' "$*" >> "$HOME/chezmoi-invocations"
case "${1:-}" in
  update)
    if [[ "${FAKE_CHEZMOI_EXIT:-0}" -ne 0 ]]; then
      exit "$FAKE_CHEZMOI_EXIT"
    fi
    ;;
  status)
    if [[ "${FAKE_CHEZMOI_STATUS_EXIT:-0}" -ne 0 ]]; then
      exit "$FAKE_CHEZMOI_STATUS_EXIT"
    fi
    [[ ! -f "$HOME/chezmoi-status" ]] || cat "$HOME/chezmoi-status"
    ;;
  apply)
    if [[ -n "${FAKE_EXPECT_BACKUP:-}" && ! -e "$FAKE_EXPECT_BACKUP" && ! -L "$FAKE_EXPECT_BACKUP" ]]; then
      echo "expected backup is missing" >&2
      exit 97
    fi
    if [[ "${FAKE_REQUIRE_BACKUP:-0}" == "1" ]] && ! find "$HOME/.cache/chezmoi-update/drift-backups" -mindepth 2 -name .bashrc -print -quit | grep -q .; then
      echo "drift backup was not created before apply" >&2
      exit 98
    fi
    exit "${FAKE_CHEZMOI_APPLY_EXIT:-0}"
    ;;
esac
exit 0
CHEZMOI
chmod +x "$bindir/chezmoi"
INSTALLER
EOF
  chmod +x "$bin_dir/curl"
}

make_fake_mise() {
  local home="$1"
  mkdir -p "$home/.local/bin"
  cat > "$home/.local/bin/mise" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$HOME/mise-invocation"
printf '%s\n' "${MISE_GLOBAL_CONFIG_FILE:-}" > "$HOME/mise-global-config"
exit "${FAKE_MISE_EXIT:-0}"
EOF
  chmod +x "$home/.local/bin/mise"
}

run_update() {
  local home="$1"
  local bin_dir="$2"
  if [[ ! -x "$home/.local/bin/mise" ]]; then
    make_fake_mise "$home"
  fi
  HOME="$home" PATH="$bin_dir:/usr/bin:/bin" bash "$SCRIPT" "${@:3}"
}

run_update_interactive() {
  local home="$1"
  local bin_dir="$2"
  if [[ ! -x "$home/.local/bin/mise" ]]; then
    make_fake_mise "$home"
  fi
  HOME="$home" PATH="$bin_dir:/usr/bin:/bin" python3 - "$SCRIPT" <<'PY'
import errno
import os
import pty
import sys

script = sys.argv[1]
pid, master = pty.fork()
if pid == 0:
    os.execl("/bin/bash", "bash", script)

output = bytearray()
while True:
    try:
        chunk = os.read(master, 4096)
    except OSError as error:
        if error.errno == errno.EIO:
            break
        raise
    if not chunk:
        break
    output.extend(chunk)

_, status = os.waitpid(pid, 0)
if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
    sys.stderr.buffer.write(output)
    sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
PY
}

echo "Testing update.sh mise failure propagation..."
TEST_HOME=$(mktemp -d)
TEST_BIN=$(mktemp -d)
make_fake_curl "$TEST_BIN"
set +e
FAKE_MISE_EXIT=43 run_update "$TEST_HOME" "$TEST_BIN"
RC=$?
set -e
[[ $RC -eq 43 ]] || { echo "❌ update.sh did not return mise exit code (got $RC)"; exit 1; }
[[ "$(cat "$TEST_HOME/mise-invocation")" == "install" ]] || { echo "❌ update.sh did not invoke mise before returning failure"; exit 1; }
[[ ! -f "$TEST_HOME/.cache/chezmoi-update/last-update" ]] || { echo "❌ update.sh recorded success after mise failure"; exit 1; }
rm -rf "$TEST_HOME" "$TEST_BIN"
echo "✅ mise failure propagation test passed"

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
[[ "$(sed -n '1p' "$TEST_HOME/chezmoi-invocations")" == "update --apply=false" ]] || { echo "❌ update.sh did not pull chezmoi source without applying first"; exit 1; }
[[ "$(sed -n '2p' "$TEST_HOME/chezmoi-invocations")" == "status --path-style=absolute --color=false" ]] || { echo "❌ update.sh did not check target drift after pulling"; exit 1; }
[[ "$(sed -n '3p' "$TEST_HOME/chezmoi-invocations")" == "apply --force" ]] || { echo "❌ update.sh did not apply after checking drift"; exit 1; }
[[ "$(cat "$TEST_HOME/mise-invocation")" == "install" ]] || { echo "❌ update.sh did not invoke mise install"; exit 1; }
[[ "$(cat "$TEST_HOME/mise-global-config")" == "$TEST_HOME/.config/mise/config.toml" ]] || { echo "❌ update.sh did not point mise at the managed global config"; exit 1; }
[[ -f "$TEST_HOME/.cache/chezmoi-update/last-update" ]] || { echo "❌ update.sh did not record successful update"; exit 1; }
rm -rf "$TEST_HOME" "$TEST_BIN"
echo "✅ canonical chezmoi path test passed"

echo "Testing interactive updater retains chezmoi update behavior..."
TEST_HOME=$(mktemp -d)
TEST_BIN=$(mktemp -d)
make_fake_curl "$TEST_BIN"
run_update_interactive "$TEST_HOME" "$TEST_BIN"
[[ "$(cat "$TEST_HOME/chezmoi-invocations")" == "update" ]] || { echo "❌ interactive update did not use chezmoi update"; exit 1; }
[[ ! -f "$TEST_HOME/chezmoi-status" ]] || { echo "❌ interactive update unexpectedly checked non-interactive drift"; exit 1; }
[[ -f "$TEST_HOME/.cache/chezmoi-update/last-update" ]] || { echo "❌ interactive update did not record success"; exit 1; }
rm -rf "$TEST_HOME" "$TEST_BIN"
echo "✅ interactive updater test passed"

echo "Testing source-only target changes do not create drift backups..."
TEST_HOME=$(mktemp -d)
TEST_BIN=$(mktemp -d)
make_fake_curl "$TEST_BIN"
printf ' M %s/.bashrc\n' "$TEST_HOME" > "$TEST_HOME/chezmoi-status"
run_update "$TEST_HOME" "$TEST_BIN"
[[ ! -e "$TEST_HOME/.cache/chezmoi-update/drift-backups" ]] || { echo "❌ source-only changes were incorrectly treated as local drift"; exit 1; }
[[ "$(sed -n '3p' "$TEST_HOME/chezmoi-invocations")" == "apply --force" ]] || { echo "❌ update.sh did not apply source-only changes"; exit 1; }
rm -rf "$TEST_HOME" "$TEST_BIN"
echo "✅ source-only status test passed"

echo "Testing deleted targets do not require a backup..."
TEST_HOME=$(mktemp -d)
TEST_BIN=$(mktemp -d)
make_fake_curl "$TEST_BIN"
printf 'D  %s/.bashrc\n' "$TEST_HOME" > "$TEST_HOME/chezmoi-status"
run_update "$TEST_HOME" "$TEST_BIN"
[[ ! -e "$TEST_HOME/.cache/chezmoi-update/drift-backups" ]] || { echo "❌ deleted target created an unnecessary backup"; exit 1; }
[[ "$(sed -n '3p' "$TEST_HOME/chezmoi-invocations")" == "apply --force" ]] || { echo "❌ update.sh did not apply a deleted target"; exit 1; }
[[ -f "$TEST_HOME/.cache/chezmoi-update/last-update" ]] || { echo "❌ deleted target update did not record success"; exit 1; }
rm -rf "$TEST_HOME" "$TEST_BIN"
echo "✅ deleted target status test passed"

echo "Testing non-interactive updater backs up locally modified targets..."
TEST_HOME=$(mktemp -d)
TEST_BIN=$(mktemp -d)
make_fake_curl "$TEST_BIN"
mkdir -p "$TEST_HOME/.config/example"
printf 'local bash config\n' > "$TEST_HOME/.bashrc"
chmod 640 "$TEST_HOME/.bashrc"
printf 'local alias config\n' > "$TEST_HOME/.config/example/aliases"
ln -s aliases "$TEST_HOME/.config/example/current"
printf 'MM %s\nMM %s\n' "$TEST_HOME/.bashrc" "$TEST_HOME/.config/example/current" > "$TEST_HOME/chezmoi-status"
FAKE_REQUIRE_BACKUP=1 run_update "$TEST_HOME" "$TEST_BIN"
BACKUP_ROOT="$TEST_HOME/.cache/chezmoi-update/drift-backups"
[[ "$(stat -c '%a' "$BACKUP_ROOT")" == "700" ]] || { echo "❌ drift backup root is not private"; exit 1; }
BACKUP_DIR=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n "$BACKUP_DIR" ]] || { echo "❌ update.sh did not create a drift backup"; exit 1; }
[[ "$(stat -c '%a' "$BACKUP_DIR")" == "700" ]] || { echo "❌ drift backup directory is not private"; exit 1; }
[[ "$(cat "$BACKUP_DIR/.bashrc")" == "local bash config" ]] || { echo "❌ update.sh did not preserve modified file contents"; exit 1; }
[[ "$(stat -c '%a' "$BACKUP_DIR/.bashrc")" == "640" ]] || { echo "❌ update.sh did not preserve modified file mode"; exit 1; }
[[ -L "$BACKUP_DIR/.config/example/current" ]] || { echo "❌ update.sh did not preserve modified symlink"; exit 1; }
[[ "$(readlink "$BACKUP_DIR/.config/example/current")" == "aliases" ]] || { echo "❌ update.sh changed the modified symlink target"; exit 1; }
[[ -f "$TEST_HOME/.cache/chezmoi-update/last-update" ]] || { echo "❌ update.sh did not record a successful backed-up update"; exit 1; }
rm -rf "$TEST_HOME" "$TEST_BIN"
echo "✅ non-interactive drift backup test passed"

echo "Testing chezmoi status failure stops before apply..."
TEST_HOME=$(mktemp -d)
TEST_BIN=$(mktemp -d)
make_fake_curl "$TEST_BIN"
set +e
FAKE_CHEZMOI_STATUS_EXIT=45 run_update "$TEST_HOME" "$TEST_BIN"
RC=$?
set -e
[[ $RC -eq 45 ]] || { echo "❌ update.sh did not return the chezmoi status exit code (got $RC)"; exit 1; }
[[ "$(wc -l < "$TEST_HOME/chezmoi-invocations" | tr -d ' ')" == "2" ]] || { echo "❌ update.sh applied changes after chezmoi status failed"; exit 1; }
[[ ! -f "$TEST_HOME/.cache/chezmoi-update/last-update" ]] || { echo "❌ update.sh recorded success after chezmoi status failed"; exit 1; }
rm -rf "$TEST_HOME" "$TEST_BIN"
echo "✅ chezmoi status failure safety test passed"

echo "Testing drift backup failure stops before apply..."
TEST_HOME=$(mktemp -d)
TEST_BIN=$(mktemp -d)
make_fake_curl "$TEST_BIN"
mkdir -p "$TEST_HOME/.cache/chezmoi-update" "$TEST_HOME/outside-backups"
ln -s "$TEST_HOME/outside-backups" "$TEST_HOME/.cache/chezmoi-update/drift-backups"
printf 'local bash config\n' > "$TEST_HOME/.bashrc"
printf 'MM %s\n' "$TEST_HOME/.bashrc" > "$TEST_HOME/chezmoi-status"
set +e
run_update "$TEST_HOME" "$TEST_BIN"
RC=$?
set -e
[[ $RC -ne 0 ]] || { echo "❌ update.sh continued after detecting an unsafe backup directory"; exit 1; }
[[ "$(wc -l < "$TEST_HOME/chezmoi-invocations" | tr -d ' ')" == "2" ]] || { echo "❌ update.sh applied changes after backup failure"; exit 1; }
[[ ! -f "$TEST_HOME/.cache/chezmoi-update/last-update" ]] || { echo "❌ update.sh recorded success after backup failure"; exit 1; }
rm -rf "$TEST_HOME" "$TEST_BIN"
echo "✅ backup failure safety test passed"

echo "Testing unsafe chezmoi status paths stop before apply..."
TEST_HOME=$(mktemp -d)
TEST_BIN=$(mktemp -d)
make_fake_curl "$TEST_BIN"
mkdir -p "$TEST_HOME/subdir" "$TEST_HOME/outside"
printf 'outside home content\n' > "$TEST_HOME/outside/file"
printf 'MM %s/subdir/../outside/file\n' "$TEST_HOME" > "$TEST_HOME/chezmoi-status"
set +e
run_update "$TEST_HOME" "$TEST_BIN"
RC=$?
set -e
[[ $RC -ne 0 ]] || { echo "❌ update.sh accepted a target path outside HOME"; exit 1; }
[[ "$(wc -l < "$TEST_HOME/chezmoi-invocations" | tr -d ' ')" == "2" ]] || { echo "❌ update.sh applied changes after rejecting an unsafe target path"; exit 1; }
[[ ! -f "$TEST_HOME/.cache/chezmoi-update/last-update" ]] || { echo "❌ update.sh recorded success after rejecting an unsafe target path"; exit 1; }
rm -rf "$TEST_HOME" "$TEST_BIN"
echo "✅ unsafe status path test passed"

echo "Testing chezmoi apply failure does not record success..."
TEST_HOME=$(mktemp -d)
TEST_BIN=$(mktemp -d)
make_fake_curl "$TEST_BIN"
set +e
FAKE_CHEZMOI_APPLY_EXIT=44 run_update "$TEST_HOME" "$TEST_BIN"
RC=$?
set -e
[[ $RC -eq 44 ]] || { echo "❌ update.sh did not return the chezmoi apply exit code (got $RC)"; exit 1; }
[[ ! -f "$TEST_HOME/.cache/chezmoi-update/last-update" ]] || { echo "❌ update.sh recorded success after chezmoi apply failure"; exit 1; }
rm -rf "$TEST_HOME" "$TEST_BIN"
echo "✅ chezmoi apply failure propagation test passed"

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
[[ "$(sed -n '1p' "$TEST_HOME/chezmoi-invocations")" == "update --apply=false" ]] || { echo "❌ --force did not invoke chezmoi update"; exit 1; }
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

echo "Testing managed chezmoi updater systemd units..."
SERVICE="home/dot_config/systemd/user/chezmoi-update.service"
TIMER="home/dot_config/systemd/user/chezmoi-update.timer"
ENABLE_LINK="home/dot_config/systemd/user/timers.target.wants/symlink_chezmoi-update.timer"
RELOAD_SCRIPT="home/run_onchange_after_20-reload-chezmoi-update-timer.sh.tmpl"
[[ -f "$SERVICE" ]] || { echo "❌ systemd service source is missing"; exit 1; }
[[ -f "$TIMER" ]] || { echo "❌ systemd timer source is missing"; exit 1; }
[[ -f "$ENABLE_LINK" ]] || { echo "❌ timer enable symlink source is missing"; exit 1; }
[[ -f "$RELOAD_SCRIPT" ]] || { echo "❌ timer reload script is missing"; exit 1; }
grep -Fq 'ExecStart=/usr/bin/mkr wrap -n chezmoi-update -d -a -w -- %h/.local/share/chezmoi/update.sh --force' "$SERVICE" || { echo "❌ service does not invoke the scheduled updater"; exit 1; }
grep -Fq 'OnCalendar=daily' "$TIMER" || { echo "❌ timer is not daily"; exit 1; }
grep -Fq 'Persistent=true' "$TIMER" || { echo "❌ timer is not persistent"; exit 1; }
grep -Fq 'RandomizedDelaySec=30m' "$TIMER" || { echo "❌ timer does not stagger scheduled updates"; exit 1; }
[[ "$(cat "$ENABLE_LINK")" == "../chezmoi-update.timer" ]] || { echo "❌ timer enable symlink target is incorrect"; exit 1; }
grep -Fq 'systemctl --user daemon-reload' "$RELOAD_SCRIPT" || { echo "❌ reload script does not reload the user manager"; exit 1; }
grep -Fq 'systemctl --user start chezmoi-update.timer' "$RELOAD_SCRIPT" || { echo "❌ reload script does not start the timer"; exit 1; }
echo "✅ managed systemd timer contract passed"

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
