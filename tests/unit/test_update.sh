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
[[ "$(cat "$TEST_HOME/chezmoi-invocation")" == "update" ]] || { echo "❌ update.sh did not invoke the canonical chezmoi binary with update"; exit 1; }
[[ "$(cat "$TEST_HOME/mise-invocation")" == "install" ]] || { echo "❌ update.sh did not invoke mise install"; exit 1; }
[[ "$(cat "$TEST_HOME/mise-global-config")" == "$TEST_HOME/.config/mise/config.toml" ]] || { echo "❌ update.sh did not point mise at the managed global config"; exit 1; }
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

echo "Testing chezmoi updater systemd units are not managed by dotfiles..."
[[ ! -e home/dot_config/systemd/user/chezmoi-update.service ]] || { echo "❌ chezmoi-update.service is still managed"; exit 1; }
[[ ! -e home/dot_config/systemd/user/chezmoi-update.timer ]] || { echo "❌ chezmoi-update.timer is still managed"; exit 1; }
[[ ! -e home/dot_config/systemd/user/timers.target.wants/symlink_chezmoi-update.timer ]] || { echo "❌ chezmoi-update.timer enable symlink is still managed"; exit 1; }
[[ ! -e home/run_onchange_after_20-reload-chezmoi-update-timer.sh.tmpl ]] || { echo "❌ chezmoi-update timer reload script is still managed"; exit 1; }
if grep -Fqx '.config/systemd/user/chezmoi-update.service' home/.chezmoiremove \
  || grep -Fqx '.config/systemd/user/chezmoi-update.timer' home/.chezmoiremove \
  || grep -Fqx '.config/systemd/user/timers.target.wants/chezmoi-update.timer' home/.chezmoiremove; then
  echo "❌ existing chezmoi updater systemd files would be removed from target hosts"
  exit 1
fi
echo "✅ chezmoi updater systemd units are unmanaged without target removal"
