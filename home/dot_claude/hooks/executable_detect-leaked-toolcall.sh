#!/bin/bash

# Stop hook: トランスクリプトの最終アシスタントメッセージに、ツールコールの
# XML マークアップ（<invoke>/<function_calls>/<parameter> 等）がプレーン
# テキストとして漏れ出していないか検出する。
# 検出時は、漏れたマークアップを引用・言い換えて再試行しない（自己模倣による
# 汚染を招く）よう指示し、意図をプロースで手短に述べたうえで、構造化された
# ツールコールを 1 回だけ発行するようブロックメッセージで促す。

DATA_DIR="$HOME/.claude/data"
LOG_FILE="$DATA_DIR/leaked-toolcall-triggers.log"

# stdin から JSON を読み込む（公式フック契約: stdin JSON）
INPUT=$(cat)

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)

# transcript_path が取得できない、またはファイルが存在しない場合はブロックしない
if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
    exit 0
fi

# Extract the concatenated text of the transcript's last assistant message.
# Arguments: $1 = transcript JSONL file path.
# Content shape varies (plain string in .message.content/.content, or an
# array of blocks where type == "text" blocks carry a .text field); both are
# normalized to a single newline-joined string. Prints nothing on failure.
extract_last_assistant_text() {
    local transcript_path="$1"
    jq -rs '
        [ .[] | select(type == "object") | select(.type == "assistant") ] | last |
        if . == null then ""
        else
            (.message.content // .content) as $c |
            if ($c | type) == "string" then $c
            elif ($c | type) == "array" then
                [ $c[] | select(.type == "text") | .text ] | join("\n")
            else "" end
        end
    ' "$transcript_path" 2>/dev/null
}

LAST_MESSAGE=$(extract_last_assistant_text "$TRANSCRIPT_PATH")

# メッセージが取得できない場合はブロックしない
if [[ -z "$LAST_MESSAGE" ]]; then
    exit 0
fi

# 漏れたツールコールマークアップの行頭パターン（大文字小文字を区別しない）
LEAK_PATTERN='^[[:space:]]*<([A-Za-z][A-Za-z0-9_.-]*:)?(invoke[[:space:]]|function_calls|parameter[[:space:]])'

MATCHED_LINE=""
while IFS= read -r line; do
    if grep -Eiq "$LEAK_PATTERN" <<< "$line"; then
        MATCHED_LINE="$line"
        break
    fi
done <<< "$LAST_MESSAGE"

# マッチなし → 正常終了
if [[ -z "$MATCHED_LINE" ]]; then
    exit 0
fi

# 検出ログを追記する（ディレクトリはオーナーのみアクセス可能 (700) で作成する）
mkdir -p "$DATA_DIR" && chmod 700 "$DATA_DIR"
printf '%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$SESSION_ID" "$MATCHED_LINE" >> "$LOG_FILE" 2>/dev/null

REASON="⚠️ 直前のアシスタントメッセージに、ツールコールの XML マークアップ(<invoke>/<function_calls>/<parameter> 等)がプレーンテキストとして漏れ出しています。

これは Claude Code の既知の不具合によるもので、実際にはツールは実行されていません。

対応手順:
1. 漏れたマークアップを引用・言い換えて再試行しないでください（自己模倣により同じ漏れを再発させる原因になります）。
2. 直前に何をしようとしていたかを、プロース文で手短に述べ直してください。
3. そのうえで、正しく構造化されたツールコールを 1 回だけ発行してください。"

jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}'
exit 0
