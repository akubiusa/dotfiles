#!/bin/bash
# bash -n による構文チェック

set -euo pipefail

echo "Checking bash syntax..."

FAILED=0

# シェル断片を含む全スクリプトを構文チェック
while IFS= read -r -d '' script; do
  # シェバンの有無を確認
  if head -n 1 "$script" | grep -qE '^#!(.*/)?(bash|sh)'; then
    # シェバンがある場合のみチェック
    if ! bash -n "$script"; then
      echo "❌ Syntax error: $script"
      FAILED=1
    else
      echo "✅ Syntax OK: $script"
    fi
  else
    # シェバンがない場合も bash として構文チェック
    if ! bash -n "$script"; then
      echo "❌ Syntax error (as bash): $script"
      FAILED=1
    else
      echo "✅ Syntax OK (as bash): $script"
    fi
  fi
done < <(find . -type f \( -name "*.sh" -o -name "executable_*" \) \
  -not -path "./.bare/*" \
  -not -path "./bin/*" \
  -print0)

# 主要な設定ファイルも bash として構文チェック
for config in home/dot_bashrc home/dot_bash_profile; do
  if [ -f "$config" ]; then
    if ! bash -n "$config"; then
      echo "❌ Syntax error: $config"
      FAILED=1
    else
      echo "✅ Syntax OK: $config"
    fi
  fi
done

# zsh 設定ファイルの構文チェック (zsh が利用可能な場合のみ)
if command -v zsh &> /dev/null; then
  for config in home/dot_zshrc; do
    if [ -f "$config" ]; then
      if ! zsh -n "$config"; then
        echo "❌ Syntax error: $config"
        FAILED=1
      else
        echo "✅ Syntax OK: $config"
      fi
    fi
  done
fi

exit $FAILED
