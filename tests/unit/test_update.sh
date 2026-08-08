#!/bin/bash
# update.sh のユニットテスト
set -euo pipefail

SCRIPT="$(pwd)/update.sh"

make_fake_curl() {
  local bin_dir="$1"
  cat > "$bin_dir/curl" <<'EOF'
#!/bin/bash
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
  HOME="$home" PATH="$bin_dir:/usr/bin:/bin" bash "$SCRIPT"
}

echo "Testing update.sh canonical chezmoi path..."
TEST_HOME=$(mktemp -d)
TEST_BIN=$(mktemp -d)
make_fake_curl "$TEST_BIN"
run_update "$TEST_HOME" "$TEST_BIN"
[[ -x "$TEST_HOME/.local/bin/chezmoi" ]] || { echo "❌ update.sh did not install chezmoi to ~/.local/bin"; exit 1; }
[[ ! -e "$TEST_HOME/bin/chezmoi" ]] || { echo "❌ update.sh installed a second chezmoi under ~/bin"; exit 1; }
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
