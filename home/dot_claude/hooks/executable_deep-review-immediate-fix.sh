#!/bin/bash

# PostToolUse hook: deep-review / lite-review スキル実行後に指摘事項の対応を促す。
# deep-review / lite-review はどちらも ledger (ledger.sh が書き込む) を読み、
# fix モードで未解決の merge-blocker があればブロックする。

STATE_DIR="$HOME/.claude/data"

# stdin から JSON を読み込む（公式フック契約: stdin JSON）
INPUT=$(cat)

# Skill ツールの実行か確認する
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
if [[ "$TOOL_NAME" != "Skill" ]]; then
    exit 0
fi

# deep-review / lite-review スキル以外はスキップする
SKILL=$(printf '%s' "$INPUT" | jq -r '.tool_input.skill_name // .tool_input.skill // ""' 2>/dev/null)
if [[ "$SKILL" != "deep-review" && "$SKILL" != "lite-review" ]]; then
    exit 0
fi

# セッション ID を取得する
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)

# deep-review / lite-review は ledger (ledger.sh が書き込む) を直接読んで判定する。
# fix モードで open な merge-blocker が残っている場合のみブロックする。
# ledger なし・schema 不一致・session 不一致・TTL 超過・破損はいずれも非ブロック (fail-open)。
if [[ "$SKILL" == "deep-review" || "$SKILL" == "lite-review" ]]; then
    [[ "$SESSION_ID" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0
    LEDGER="${DEEP_REVIEW_DATA_DIR:-$STATE_DIR}/deep-review-ledger-${SESSION_ID}.json"
    [[ -f "$LEDGER" ]] || exit 0
    if ! COUNT=$(jq -r --arg s "$SESSION_ID" '
        if .schema_version == 1 and .session_id == $s and (now - .updated_at) <= 86400 and .mode == "fix"
        then [.findings[] | select(.class == "merge-blocker" and .status == "open")] | length
        else 0 end' "$LEDGER" 2>/dev/null); then
        echo "WARNING: corrupted deep-review ledger: $LEDGER" >&2
        exit 0
    fi
    if [[ "$COUNT" -gt 0 ]]; then
        REASON="🔔 ${SKILL} (fix モード) で ${COUNT} 件の未解決のマージ前必須指摘が残っています。

対応手順:
1. ledger の open な merge-blocker 指摘をすべて確認する
2. 各指摘を修正して検証し、ledger.sh で status を fixed / false_positive / deferred に更新する
3. 修正内容をコミット・プッシュする
4. PR 本文を更新する

対応漏れは禁止されています。"
        jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}'
    fi
    exit 0
fi
