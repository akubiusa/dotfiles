#!/bin/bash

# Stop hook: セッション終了時に deep-review / lite-review の未対応指摘が残っていないか検証する。
# deep-review は ledger (ledger.sh が書き込む) を直接読んで判定する。
# lite-review のみ、PostToolUse フックが書き出した旧ステートファイル
# (~/.claude/data/deep-review-state-*.json) で判定する。
# ledger もステートファイルも存在しない場合はブロックしない（セッション内でどちらも未実行）。

STATE_DIR="$HOME/.claude/data"

# stdin から JSON を読み込む（公式フック契約: stdin JSON）
INPUT=$(cat)

# 現在のセッション ID を取得する
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)

# セッション ID が英数字・ハイフン・アンダースコアのみで構成されているか検証する
# （immediate-fix.sh と同一の検証。書き込み側と読み込み側で判定がずれると
# 常にステートファイルが見つからずブロックが機能しなくなるため揃える）。
# 一致しない場合は後方互換のため旧形式の固定パスにフォールバックする。
if [[ "$SESSION_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    STATE_FILE="$STATE_DIR/deep-review-state-${SESSION_ID}.json"
else
    STATE_FILE="$STATE_DIR/deep-review-state.json"
fi

# deep-review は ledger を直接読んで判定する。fix モードで open な merge-blocker が残っている場合のみブロックする。
# ledger なし・schema/session 不一致・TTL 超過・破損は非ブロック。
if [[ "$SESSION_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    LEDGER="${DEEP_REVIEW_DATA_DIR:-$STATE_DIR}/deep-review-ledger-${SESSION_ID}.json"
    if [[ -f "$LEDGER" ]]; then
        if COUNT=$(jq -r --arg s "$SESSION_ID" '
            if .schema_version == 1 and .session_id == $s and (now - .updated_at) <= 86400 and .mode == "fix"
            then [.findings[] | select(.class == "merge-blocker" and .status == "open")] | length
            else 0 end' "$LEDGER" 2>/dev/null); then
            if [[ "$COUNT" -gt 0 ]]; then
                REASON="⚠️ deep-review (fix モード) で ${COUNT} 件の未解決のマージ前必須指摘が残っています。

対応手順:
1. ledger の open な merge-blocker 指摘をすべて確認する
2. 各指摘を修正して検証し、ledger.sh で status を fixed / false_positive / deferred に更新する
3. 修正内容をコミット・プッシュする
4. PR 本文を更新する"
                jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}'
                exit 0
            fi
        else
            echo "WARNING: corrupted deep-review ledger: $LEDGER" >&2
        fi
    fi
fi

# 以降は lite-review 用の旧ステートファイル判定。
# ステートファイルが存在しない → このセッションで deep-review / lite-review 未実行 → ブロックしない
if [[ ! -f "$STATE_FILE" ]]; then
    exit 0
fi

# ステートファイルを読み込む
STATE_SESSION=$(jq -r '.session_id // ""' "$STATE_FILE" 2>/dev/null)
STATE_TIMESTAMP=$(jq -r '.timestamp // 0' "$STATE_FILE" 2>/dev/null)
HIGH_SCORE_COUNT=$(jq -r '.high_score_count // 0' "$STATE_FILE" 2>/dev/null)
MAX_SCORE=$(jq -r '.max_score // 0' "$STATE_FILE" 2>/dev/null)
# skill フィールドが無い旧形式ファイルは lite-review ではないものとして扱い、下のガードで無視する
STATE_SKILL=$(jq -r '.skill // "deep-review"' "$STATE_FILE" 2>/dev/null)

# 旧判定を使うのは lite-review のみ。deep-review と skill フィールドなしの旧形式ステートは無視する
if [[ "$STATE_SKILL" != "lite-review" ]]; then
    exit 0
fi

# ステートファイルの有効期限（24時間）
STATE_TTL=86400
CURRENT_TIME=$(date +%s)
STATE_AGE=$(( CURRENT_TIME - STATE_TIMESTAMP ))

# セッション ID が一致しない、または SESSION_ID はあるのに STATE_SESSION が
# 空（旧形式ファイル、他セッション由来の可能性あり）の場合は信頼しない
if [[ -n "$SESSION_ID" && "$SESSION_ID" != "$STATE_SESSION" ]]; then
    exit 0
fi

# ここに到達するのは、SESSION_ID が一致した場合、または SESSION_ID 自体が
# 空（stdin から取得できなかった後方互換ケース）の場合のみ。TTL で判定する
if [[ "$STATE_AGE" -gt "$STATE_TTL" ]]; then
    exit 0
fi

# スコア 50 以上の指摘が残っている場合はセッション終了をブロックする
if [[ "$HIGH_SCORE_COUNT" -gt 0 ]]; then
    REASON="⚠️ ${STATE_SKILL} で ${HIGH_SCORE_COUNT} 件の重要な指摘事項が見つかりました（最高スコア: ${MAX_SCORE}）。

CLAUDE.md のルールに従い、スコア 50 以上の指摘事項に対応してから終了してください。

対応手順:
1. スコア 50 以上の指摘をすべて確認する
2. 各指摘に対して適切な修正を実施する
3. 修正内容をコミット・プッシュする
4. PR 本文を更新する
5. 必要に応じて再度 /${STATE_SKILL} を実施する"
    jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}'
    exit 0
fi

# 対応済みまたは指摘なし
exit 0
