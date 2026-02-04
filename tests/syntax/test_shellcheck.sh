#!/bin/bash
# shellcheck によるシェルスクリプトの静的解析

set -euo pipefail

echo "Running shellcheck on all shell scripts..."

FAILED=0

# シェル断片 (shebang なし) を含む全スクリプトを検査
# -print0 と while read でパス名の空白を安全に処理
while IFS= read -r -d '' script; do
  # シェバンの有無と種類を確認
  if head -n 1 "$script" | grep -qE '^#!(.*/)?(bash|sh)'; then
    # bash / sh の shebang がある場合
    if ! shellcheck "$script"; then
      echo "❌ Shellcheck failed: $script"
      FAILED=1
    else
      echo "✅ Shellcheck passed: $script"
    fi
  elif head -n 1 "$script" | grep -qE '^#!(.*/)?zsh'; then
    # zsh の shebang がある場合
    if ! shellcheck -s zsh "$script"; then
      echo "❌ Shellcheck failed: $script"
      FAILED=1
    else
      echo "✅ Shellcheck passed: $script"
    fi
  else
    # シェバンがない場合は拡張子で判定
    if [[ "$script" == *.zsh ]]; then
      # .zsh 拡張子のファイルは zsh として解析
      if ! shellcheck -s zsh "$script"; then
        echo "❌ Shellcheck failed (as zsh): $script"
        FAILED=1
      else
        echo "✅ Shellcheck passed (as zsh): $script"
      fi
    else
      # それ以外は bash として明示的に解析
      if ! shellcheck -s bash "$script"; then
        echo "❌ Shellcheck failed (as bash): $script"
        FAILED=1
      else
        echo "✅ Shellcheck passed (as bash): $script"
      fi
    fi
  fi
done < <(find . -type f \( -name "*.sh" -o -name "executable_*" \) \
  -not -path "./.bare/*" \
  -not -path "./bin/*" \
  -print0)

# 主要な設定ファイルも bash として検査
for config in home/dot_bashrc home/dot_bash_profile; do
  if [ -f "$config" ]; then
    if ! shellcheck -s bash "$config"; then
      echo "❌ Shellcheck failed: $config"
      FAILED=1
    else
      echo "✅ Shellcheck passed: $config"
    fi
  fi
done

exit $FAILED
