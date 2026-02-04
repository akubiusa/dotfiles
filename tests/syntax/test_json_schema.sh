#!/bin/bash
# AI エージェント設定ファイルの JSON Schema バリデーション

set -euo pipefail

echo "Validating AI agent configuration files..."

# check-jsonschema のインストール確認
if ! command -v check-jsonschema &> /dev/null; then
  echo "Installing check-jsonschema..."
  pip install check-jsonschema
fi

FAILED=0

# Claude Code settings.json (公式スキーマを使用)
if [ -f "home/dot_claude/settings.json" ]; then
  echo "Validating Claude Code settings.json..."
  if ! check-jsonschema --schemafile https://json.schemastore.org/claude-code-settings.json home/dot_claude/settings.json; then
    echo "❌ Claude Code settings.json validation failed"
    FAILED=1
  else
    echo "✅ Claude Code settings.json validation passed"
  fi
fi

# Gemini CLI settings.json (公式スキーマを使用)
if [ -f "home/dot_gemini/settings.json" ]; then
  echo "Validating Gemini CLI settings.json..."
  if ! check-jsonschema --schemafile https://raw.githubusercontent.com/google-gemini/gemini-cli/main/schemas/settings.schema.json home/dot_gemini/settings.json; then
    echo "❌ Gemini CLI settings.json validation failed"
    FAILED=1
  else
    echo "✅ Gemini CLI settings.json validation passed"
  fi
fi

echo "✅ All AI agent configuration files validated"
exit $FAILED
