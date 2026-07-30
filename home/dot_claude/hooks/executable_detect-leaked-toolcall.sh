#!/bin/bash

# Stop / SubagentStop hook: トランスクリプトの最終アシスタントメッセージに、
# ツールコールの XML マークアップ（<invoke>/<function_calls>/<parameter> 等）が
# プレーンテキストとして漏れ出していないか検出する。
# 検出時は、漏れたマークアップを引用・言い換えて再試行しない（自己模倣による
# 汚染を招く）よう指示し、意図をプロースで手短に述べたうえで、構造化された
# ツールコールを 1 回だけ発行するようブロックメッセージで促す。

DATA_DIR="$HOME/.claude/data"
LOG_FILE="$DATA_DIR/leaked-toolcall-triggers.log"

# 引用されたマークアップや、このスキル自体を話題にしたメッセージ等の
# 誤検知が同一セッション内で繰り返しブロックし続けセッションが行き詰まる
# 事態を避けるため、セッションあたりの発火回数に上限を設ける
MAX_TRIGGERS_PER_SESSION=3

# stdin から JSON を読み込む（公式フック契約: stdin JSON）
INPUT=$(cat)

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)

# transcript_path が取得できない、またはファイルが存在しない場合はブロックしない
if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
    exit 0
fi

# トランスクリプトの最終アシスタントメッセージのテキストを連結して取り出す。
# 引数: $1 = トランスクリプト JSONL ファイルのパス。
# トランスクリプトは数十 MB に達することがあり、全体を jq -s でスラープすると
# 遅い上、途中に壊れた行が 1 行でもあると全体の解析が失敗し検出漏れになる。
# そのため末尾のみを対象にし（末尾に近いほど「最終アシスタントメッセージ」に
# 該当する可能性が高い）、壊れた行は try/catch で読み飛ばしてから最後の
# assistant メッセージだけを採用する。content は文字列、またはブロック配列
# （type == "text" のブロックのみ採用）のどちらの形もあり、両方を改行区切りの
# 単一文字列に正規化する。失敗時は何も出力しない。
extract_last_assistant_text() {
    local transcript_path="$1"
    tail -n 300 "$transcript_path" | jq -Rrs '
        split("\n")
        | map(select(length > 0))
        | map(try fromjson catch null)
        | map(select(. != null and .type == "assistant"))
        | last
        | if . == null then ""
          else
              (.message.content // .content) as $c
              | if ($c | type) == "string" then $c
                elif ($c | type) == "array" then
                    ([$c[] | select(.type == "text") | .text] | join("\n"))
                else "" end
          end
    ' 2>/dev/null
}

LAST_MESSAGE=$(extract_last_assistant_text "$TRANSCRIPT_PATH")

# メッセージが取得できない場合はブロックしない
if [[ -z "$LAST_MESSAGE" ]]; then
    exit 0
fi

# 漏れたツールコールマークアップのパターン（大文字小文字を区別しない）。
# 閉じタグ（/? による任意のスラッシュ）や属性なしの短縮形（<invoke>,
# </invoke> 等）も拾えるよう、invoke/parameter 直後の空白必須要件は
# 課さず、タグ名の直後が空白・スラッシュ・`>`・行末のいずれかであることのみ
# 要求する。行頭アンカーは意図的に外している（プロースの途中から漏れが
# 始まるケースを拾うため）。そのぶん、ツールコール構文を引用・説明する
# メッセージに対する誤検知がわずかに増えるが、下記のセッション単位の
# 発火回数上限で影響を抑える。
LEAK_PATTERN='<(/)?([A-Za-z][A-Za-z0-9_.-]*:)?(invoke|function_calls|parameter)([[:space:]/>]|$)'

MATCHED_LINE=$(grep -Eim1 "$LEAK_PATTERN" <<< "$LAST_MESSAGE")

# マッチなし → 正常終了
if [[ -z "$MATCHED_LINE" ]]; then
    exit 0
fi

# ログにはマッチした行全体ではなく、マッチしたタグ断片のみを記録する。
# 行全体には漏れたツールコールの引数（シークレットやファイル内容を含み
# うる）が含まれる可能性があり、そのままログへ書き出すと
# rules/security.md の「シークレット値をログへ残さない」に反するため。
MATCHED_MARKER=$(grep -Eiom1 "$LEAK_PATTERN" <<< "$MATCHED_LINE")

# セッション ID が英数字・ハイフン・アンダースコアのみで構成されているか検証する
# （deep-review-require-fixes.sh 等と同一の検証。不正な値をファイルパスへ
# 直接展開すると意図しないディレクトリへの書き込みを招くため、一致しない
# 場合は固定名ファイルにフォールバックする）
if [[ "$SESSION_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    COUNT_FILE="$DATA_DIR/leaked-toolcall-count-${SESSION_ID}"
else
    COUNT_FILE="$DATA_DIR/leaked-toolcall-count.txt"
fi

mkdir -p "$DATA_DIR" 2>/dev/null && chmod 700 "$DATA_DIR" 2>/dev/null

# 検出ログを追記する（ログファイル自体もオーナーのみ読み書き可能にする）
printf '%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$SESSION_ID" "$MATCHED_MARKER" 2>/dev/null >> "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null

CURRENT_COUNT=0
if [[ -f "$COUNT_FILE" ]]; then
    CURRENT_COUNT=$(cat "$COUNT_FILE" 2>/dev/null)
    [[ "$CURRENT_COUNT" =~ ^[0-9]+$ ]] || CURRENT_COUNT=0
fi

# 上限に達している場合はブロックしない（誤検知による無限ブロックループを回避）
if [[ "$CURRENT_COUNT" -ge "$MAX_TRIGGERS_PER_SESSION" ]]; then
    exit 0
fi

printf '%s\n' "$((CURRENT_COUNT + 1))" 2>/dev/null > "$COUNT_FILE"
chmod 600 "$COUNT_FILE" 2>/dev/null

REASON="⚠️ 直前のアシスタントメッセージに、ツールコールの XML マークアップ(<invoke>/<function_calls>/<parameter> 等、閉じタグ・属性なしの短縮形を含む)がプレーンテキストとして漏れ出しています。

これは Claude Code の既知の不具合によるもので、実際にはツールは実行されていません。

対応手順:
1. 漏れたマークアップを引用・言い換えて再試行しないでください（自己模倣により同じ漏れを再発させる原因になります）。
2. 直前に何をしようとしていたかを、プロース文で手短に述べ直してください。
3. そのうえで、正しく構造化されたツールコールを 1 回だけ発行してください。"

jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}'
exit 0
