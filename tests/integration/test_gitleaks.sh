#!/bin/bash
# mise で固定した gitleaks が実際に既知形式のシークレットを検出できることを確認する
set -euo pipefail

CONFIG="home/dot_config/mise/config.toml"
VERSION=$(sed -n 's/^gitleaks = "\([0-9][0-9.]*\)"$/\1/p' "$CONFIG")
if [[ -z "$VERSION" ]]; then
  echo "❌ gitleaks must be pinned to an exact version in $CONFIG"
  exit 1
fi

case "$(uname -m)" in
  x86_64) ASSET_ARCH="x64" ;;
  aarch64|arm64) ASSET_ARCH="arm64" ;;
  *) echo "❌ unsupported architecture for gitleaks smoke test: $(uname -m)"; exit 1 ;;
esac

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
ARCHIVE="$TMP_DIR/gitleaks.tar.gz"
URL="https://github.com/gitleaks/gitleaks/releases/download/v${VERSION}/gitleaks_${VERSION}_linux_${ASSET_ARCH}.tar.gz"
curl -fsSL "$URL" -o "$ARCHIVE"
tar -xzf "$ARCHIVE" -C "$TMP_DIR" gitleaks

FIXTURE="$TMP_DIR/fixture.txt"
printf 'token = "ghp_%s%s"\n' 'aBcDeFgHiJkLmNoPqRsT' 'uVwXyZ0123456789' > "$FIXTURE"
set +e
"$TMP_DIR/gitleaks" detect --no-git --source "$FIXTURE" --no-banner --redact > "$TMP_DIR/output" 2>&1
RC=$?
set -e
if [[ $RC -eq 0 ]]; then
  cat "$TMP_DIR/output"
  echo "❌ gitleaks $VERSION failed to detect the regression fixture"
  exit 1
fi
if ! grep -qi 'leaks found' "$TMP_DIR/output"; then
  cat "$TMP_DIR/output"
  echo "❌ gitleaks $VERSION failed for an unexpected reason"
  exit 1
fi

echo "✅ gitleaks $VERSION detects the regression fixture"

# 実際の pre-commit hook と固定バージョンの組み合わせでもコミットをブロックできることを確認する。
TEST_REPO="$TMP_DIR/repo"
TEST_HOME="$TMP_DIR/home"
TEST_BIN="$TMP_DIR/bin"
mkdir -p "$TEST_REPO" "$TEST_HOME" "$TEST_BIN"
cp "$TMP_DIR/gitleaks" "$TEST_BIN/gitleaks"
cp home/dot_gitleaks.toml "$TEST_HOME/.gitleaks.toml"
(
  cd "$TEST_REPO"
  git init -q
  git config user.name test
  git config user.email test@example.invalid
  cp "$FIXTURE" secret.txt
  git add secret.txt
  set +e
  HOME="$TEST_HOME" PATH="$TEST_BIN:/usr/bin:/bin" bash "$OLDPWD/home/dot_config/git/hooks/executable_pre-commit" > "$TMP_DIR/hook-output" 2>&1
  HOOK_RC=$?
  set -e
  if [[ $HOOK_RC -eq 0 ]]; then
    cat "$TMP_DIR/hook-output"
    echo "❌ pre-commit hook did not block the regression fixture with gitleaks $VERSION"
    exit 1
  fi
)
echo "✅ pre-commit hook blocks the regression fixture with gitleaks $VERSION"
