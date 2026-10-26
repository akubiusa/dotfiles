#!/bin/bash
# Codex CLI のリミット到達・解除を、rollout ログ (jsonl) に記録される構造化イベントから
# 検出し、Discord 通知とセッション再開を行う。
#
# tmux ペインの画面表示テキストは Bash ツール実行中などに前面プロセスや
# 表示内容が一時的に切り替わることで誤検出(フラッピング)が起きるため走査しない。
# 代わりに、tmux セッションの pid 配下のプロセスが実際に開いている rollout jsonl の
# ファイルパスを特定し、その内容でリミット状態を判定する。
#
# 想定 crontab (このリポジトリでは管理しない。ユーザーが別途登録する):
#   1-59/5 * * * * ~/.codex/scripts/limit-unlocked/check-notify.sh

# 指定した pid の子孫すべての pid を、pid→ppid の対応表を 1 回の ps 呼び出しで
# 取得した上で awk 側でツリーを再構成して列挙する(自分自身を含む)。
# codex の実体は tmux ペインの直接の子プロセスとは限らず(例:
# bash -> codex --yolo -> codex-code-mode-host、あるいは
# node /path/to/bin/codex --yolo のように node が親になる場合もある)、
# どのプロセス名が実際の codex 本体かを仮定できないため、子孫を再帰的に
# すべて集めた上で fd 走査を行う。祖先ごとに pgrep を再帰呼び出しする方式は
# 子孫数に比例して fork コストが線形に積み上がるため避ける
collect_descendant_pids() {
    local root_pid="$1"
    ps -eo pid,ppid --no-headers 2>/dev/null | awk -v root="$root_pid" '
        { ppid[$1] = $2 }
        END {
            queue[1] = root
            qlen = 1
            print root
            seen[root] = 1
            for (i = 1; i <= qlen; i++) {
                cur = queue[i]
                for (p in ppid) {
                    if (ppid[p] == cur && !(p in seen)) {
                        print p
                        seen[p] = 1
                        qlen++
                        queue[qlen] = p
                    }
                }
            }
        }
    '
}

# fd_dirs (/proc/<pid>/fd の並び) の中から rollout-*.jsonl を指す fd を集め、
# 最有力候補を 1 つ選ぶ。標準出力: 選ばれたパス(候補がなければ何も出力しない)。
#
# require_cwd が非空の場合、ファイル内容にその文字列を含まない候補は除外する。
# session_meta.cwd は daemon 経由だと実際の pane cwd を反映しないため使えず、
# 代わりにツール呼び出しの本文中に現れる cwd 文字列を頼りにしている。
# これは、複数セッション分の rollout を同時に保持する daemon 経由の探索で、
# 無関係なセッションを誤って選ばないための絞り込みである。
#
# 候補が複数残った場合は、親セッションの rollout を subagent の rollout より優先する。
# 同種の候補内では最終更新時刻が最も新しいもの(実際に追記され続けている rollout)を選ぶ。
#
# fd ごとに readlink -f を fork する方式は、procfs 上の無関係な fd も全数チェックし低速。
# そのため find -lname によるシンボリックリンク先パターンマッチ 1 回にまとめている。
select_best_rollout() {
    local home_real="$1" require_cwd="$2"
    shift 2
    local fd_dirs=("$@")
    local target mtime thread_source is_subagent
    local best_path="" best_mtime=-1 best_is_subagent=1

    [ "${#fd_dirs[@]}" -gt 0 ] || return 0

    while IFS= read -r target; do
        [ -n "$target" ] || continue
        # cwd を単純な部分一致で探すと、cwd が他セッションのより深いパスの
        # プレフィックスに過ぎない場合まで誤ってマッチしてしまう。cwd の直後が
        # パス構成文字(英数字・"_"・"."・"-"・"/")でないことを要求し、
        # cwd がファイル内容中で完結した単独のパスとして現れる場合だけに絞る
        if [ -n "$require_cwd" ] && ! grep -qP -- "\\Q${require_cwd}\\E(?![A-Za-z0-9_./-])" "$target" 2>/dev/null; then
            continue
        fi
        mtime=$(stat -c %Y "$target" 2>/dev/null) || continue

        # multi-agent 実行では親と subagent の rollout が同時に開かれる。subagent が
        # 親より数秒遅く完了すると mtime だけでは subagent を選び、親側に記録された
        # usage_limit_exceeded を見落とすため session_meta で親を優先する。
        thread_source=$(head -n 1 "$target" 2>/dev/null | jq -r 'select(.type == "session_meta") | .payload.thread_source // empty' 2>/dev/null)
        is_subagent=0
        [ "$thread_source" = "subagent" ] && is_subagent=1

        if [ -z "$best_path" ] \
            || { [ "$best_is_subagent" -eq 1 ] && [ "$is_subagent" -eq 0 ]; } \
            || { [ "$best_is_subagent" -eq "$is_subagent" ] && [ "$mtime" -gt "$best_mtime" ]; }
        then
            best_mtime="$mtime"
            best_path="$target"
            best_is_subagent="$is_subagent"
        fi
    done < <(find "${fd_dirs[@]}" -lname "${home_real}/.codex/sessions/*/*/*/rollout-*.jsonl" -printf '%l\n' 2>/dev/null)

    [ -n "$best_path" ] && echo "$best_path"
    return 0
}

# ペインの子孫 pid の中に、共有 app-server daemon へ接続する codex クライアント
# (`codex --remote ...`) が存在するかを調べる。
#
# claude など codex 以外のセッションが daemon フォールバックの対象になると、
# pane の cwd の偶然の一致だけで無関係な rollout に誤って紐付きうる。
# この関数はその発動条件を絞り込むためのものである。
has_remote_codex_client() {
    local pid comm cmdline
    for pid in "$@"; do
        comm=$(cat "/proc/$pid/comm" 2>/dev/null) || continue
        [ "$comm" = "codex" ] || continue
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        case "$cmdline" in
            *--remote*) return 0 ;;
        esac
    done
    return 1
}

# tmux セッション名から、対応する codex プロセス群が書き込んでいる rollout jsonl の
# パスを特定する。
#
# Codex には Claude Code の sessions/<pid>.json のような pid→セッション対応表が
# 存在しないため、まず pane の pid とその子孫すべてのオープン fd を走査する。
# 90-ai-alias.sh の codex() ラッパーが直接起動したセッションはここで見つかる。
#
# 同ラッパーは共有 app-server daemon (codex app-server --remote-control) が
# 稼働中だと `codex --remote unix://` で接続する。
# この場合 TUI は daemon への薄いクライアントになる。
# この場合 rollout fd はペインの子孫プロセスではなく daemon プロセス側に開かれる。
# そのため子孫 fd 走査だけでは見つからない。
#
# そのため daemon プロセスの fd を対象に、ペインの cwd を含む rollout だけに絞って
# select_best_rollout を再実行する。
# daemon は複数セッション分の rollout を同時に保持しうるため、
# この cwd 絞り込みが必須である。
resolve_rollout_path() {
    local session="$1" pane_pid pane_cwd home_real fd_dirs=() daemon_fd_dirs=() pid best_path
    local descendant_pids=()

    # tmux はターゲットが "0" のような裸の数字だと、セッション名ではなく
    # 「未指定」とみなして現在アクティブなセッションへフォールバックしてしまう
    # ため、末尾に ":" を付けてセッション名指定であることを明示する
    pane_pid=$(tmux display-message -t "${session}:" -p '#{pane_pid}' 2>/dev/null) || return 1
    [ -n "$pane_pid" ] || return 1
    pane_cwd=$(tmux display-message -t "${session}:" -p '#{pane_current_path}' 2>/dev/null)

    # readlink -f はシンボリックリンクを最後まで解決した絶対パスを返すため、$HOME 自体に
    # シンボリックリンク成分が含まれる環境ではそのまま比較すると常に不一致になる。
    # 比較対象も同じ readlink -f で正規化しておく
    home_real=$(readlink -f "$HOME" 2>/dev/null) || home_real="$HOME"

    mapfile -t descendant_pids < <(collect_descendant_pids "$pane_pid")
    for pid in "${descendant_pids[@]}"; do
        [ -d "/proc/$pid/fd" ] && fd_dirs+=("/proc/$pid/fd")
    done
    if [ "${#fd_dirs[@]}" -gt 0 ]; then
        best_path=$(select_best_rollout "$home_real" "" "${fd_dirs[@]}")
        if [ -n "$best_path" ]; then
            echo "$best_path"
            return 0
        fi
    fi

    # ペインに codex --remote クライアントがいないなら daemon フォールバックの対象外
    # (claude セッションなど、そもそも codex と無関係なペインを除外する)
    has_remote_codex_client "${descendant_pids[@]}" || return 1

    # ponytail: cwd が単独パスとして現れるかで候補を絞ってはいるが、なお誤選択の
    # 余地は残るヒューリスティクスである。
    # 同一ディレクトリで複数の tmux セッションが同時に --remote 接続している場合や、
    # 複数の daemon プロセスが同時に生き残っている場合が該当する。
    # 必要になれば daemon 側の JSON-RPC でセッション⇔接続の対応を
    # 直接問い合わせる方式に upgrade する。
    [ -n "$pane_cwd" ] || return 1
    for pid in $(pgrep -f 'app-server --remote-control' 2>/dev/null); do
        [ -d "/proc/$pid/fd" ] && daemon_fd_dirs+=("/proc/$pid/fd")
    done
    [ "${#daemon_fd_dirs[@]}" -gt 0 ] || return 1

    best_path=$(select_best_rollout "$home_real" "$pane_cwd" "${daemon_fd_dirs[@]}")
    [ -n "$best_path" ] || return 1
    echo "$best_path"
}

# rollout jsonl の直近のイベントを見て、リミット到達中かどうかと再開予定時刻(epoch)を
# 判定する。標準出力: "<status:0|1|2>\t<reset_epoch>\t<reset_text>\t<turn_id>"
# status: 0 = リミットなし、1 = リミット到達中、2 = 判定不能(jsonl の走査対象範囲を
# jq が解析できなかった等)。2 を 0 と区別せず返すと、解析エラーを「解除」と誤判定して
# しまうため、呼び出し元(detect_limited_sessions)は 2 を resolve 失敗と同様に扱う
check_limit_status() {
    local jsonl="$1" tail_lines last_task_complete last_task_complete_line jq_exit is_err text completed_at
    local token_line later_token_line reset_epoch date_text turn_id

    [ -f "$jsonl" ] || { printf '0\t-\t-\t-\n'; return; }

    # jsonl は会話全体で大きくなりうるが直近のイベントが分かればよいため、
    # 末尾のみを走査対象にして cron の定期実行での毎回フルパースを避ける
    tail_lines=$(tail -n 200 "$jsonl")

    last_task_complete=$(echo "$tail_lines" | jq -c 'select(.type == "event_msg" and .payload.type == "task_complete") | {event: ., line: input_line_number}' 2>/dev/null)
    jq_exit=$?
    if [ "$jq_exit" -ne 0 ]; then
        printf '2\t-\t-\t-\n'
        return
    fi
    last_task_complete=$(echo "$last_task_complete" | tail -1)
    [ -n "$last_task_complete" ] || { printf '0\t-\t-\t-\n'; return; }
    last_task_complete_line=$(echo "$last_task_complete" | jq -r '.line' 2>/dev/null)
    last_task_complete=$(echo "$last_task_complete" | jq -c '.event' 2>/dev/null)

    is_err=$(echo "$last_task_complete" | jq -r '(.payload.error != null) and (.payload.error.codex_error_info == "usage_limit_exceeded")' 2>/dev/null)
    if [ "$is_err" != "true" ]; then
        printf '0\t-\t-\t-\n'
        return
    fi

    text=$(echo "$last_task_complete" | jq -r '.payload.error.message // ""' 2>/dev/null)
    # text は会話ログ由来の自由形式文字列。タブ・改行を含み得るため、そのまま
    # 状態ファイル(タブ区切り 1 行 1 レコード)へ埋め込むとレコード構造が壊れる。
    # 通知文言としての可読性は保ったまま、区切り文字だけを空白に置き換える
    text=$(echo "$text" | tr '\t\n' '  ')
    completed_at=$(echo "$last_task_complete" | jq -r '.payload.completed_at // empty' 2>/dev/null)
    # resume 重複排除キーとして使う(下記 resume_key_for を参照)。text と同様、
    # タブ区切りの状態ファイルへそのまま埋め込むとレコード構造が壊れるためサニタイズする
    turn_id=$(echo "$last_task_complete" | jq -r '.payload.turn_id // empty' 2>/dev/null)
    turn_id=$(printf '%s' "$turn_id" | tr '\t\n' '  ')

    later_token_line=$(echo "$tail_lines" | jq -c --argjson task_complete_line "$last_task_complete_line" 'select(input_line_number > $task_complete_line and .type == "event_msg" and .payload.type == "token_count")' 2>/dev/null | tail -1)
    if [ -n "$later_token_line" ] && [ "$(echo "$later_token_line" | jq -r '
        (.payload.rate_limits? // null) as $rate_limits
        | if ($rate_limits | type) != "object" then false
          else [
              $rate_limits.primary?,
              $rate_limits.secondary?
              | select(type == "object")
          ] as $windows
          | ($windows | length) > 0
            and all($windows[]; (.used_percent? | type) == "number" and .used_percent < 100)
          end
    ' 2>/dev/null)" = "true" ]; then
        printf '0\t-\t-\t-\n'
        return
    fi

    token_line=$(echo "$tail_lines" | jq -c 'select(.type == "event_msg" and .payload.type == "token_count")' 2>/dev/null | tail -1)
    reset_epoch=""
    if [ -n "$token_line" ]; then
        # primary/secondary のうち実際に上限(100%)へ達しているウィンドウの resets_at を
        # 優先する。無条件に primary を優先すると、primary がまだ余裕のある状態で
        # secondary (weekly 等) が先に上限に達しているケースの再開予定時刻を取り違える
        reset_epoch=$(echo "$token_line" | jq -r '
            .payload.rate_limits as $rl
            | if (($rl.primary.used_percent // 0) >= 100) then $rl.primary.resets_at
              elif (($rl.secondary.used_percent // 0) >= 100) then $rl.secondary.resets_at
              else ($rl.primary.resets_at // $rl.secondary.resets_at)
              end
            // empty
        ' 2>/dev/null)
    fi

    if ! [[ "$reset_epoch" =~ ^[0-9]+$ ]]; then
        # 取得できない場合のみ payload.error.message 内の "try again at ..." という
        # 日付文言をフォールバックとしてパースする(序数接尾辞 st/nd/rd/th は
        # date -d が解釈できないため事前に取り除く)
        date_text=$(echo "$text" | grep -oiE 'try again at [^.]+' | sed -E 's/^[Tt]ry again at //')
        date_text=$(echo "$date_text" | sed -E 's/([0-9]+)(st|nd|rd|th)/\1/')
        if [ -n "$date_text" ]; then
            reset_epoch=$(date -d "$date_text" +%s 2>/dev/null)
        fi
    fi

    if ! [[ "$reset_epoch" =~ ^[0-9]+$ ]]; then
        # それも失敗した場合は completed_at + 24 時間を仮の再開予定とする
        if [[ "$completed_at" =~ ^[0-9]+$ ]]; then
            reset_epoch=$((completed_at + 24 * 3600))
        else
            reset_epoch=""
        fi
    fi

    printf '1\t%s\t%s\t%s\n' "${reset_epoch:--}" "$text" "${turn_id:--}"
}

# resolve_rollout_path の特定失敗(または check_limit_status の判定不能)が
# 連続して何回続いているかを保持するファイルのパス。プロセス終了などで恒久的に
# 特定不能になったセッションを、前回記録のまま無期限に引き継ぎ続けないための
# カウンタとして使う
resolve_failure_count_file() {
    echo "$HOME/.codex/scripts/limit-unlocked/data/resolve_failures.txt"
}

get_resolve_failure_count() {
    local session="$1" file count
    file=$(resolve_failure_count_file)
    [ -f "$file" ] || { echo 0; return; }
    count=$(awk -F'\t' -v s="$session" '$1 == s { print $2; exit }' "$file")
    [[ "$count" =~ ^[0-9]+$ ]] && echo "$count" || echo 0
}

set_resolve_failure_count() {
    local session="$1" count="$2" file tmp_file
    file=$(resolve_failure_count_file)
    mkdir -p "$(dirname "$file")"
    touch "$file"
    tmp_file="${file}.tmp.$$"
    if [ "$count" -le 0 ]; then
        awk -F'\t' -v s="$session" '$1 != s { print }' "$file" > "$tmp_file"
    else
        { awk -F'\t' -v s="$session" '$1 != s { print }' "$file"; printf '%s\t%s\n' "$session" "$count"; } > "$tmp_file"
    fi
    mv "$tmp_file" "$file"
}

# 前回記録(STATE_FILE)の該当セッション行を、confirmed=0(このポーリングでは
# 再検証できていない)として $NEW_STATE_FILE へ引き継ぐ。連続失敗回数が閾値を
# 超えた場合は引き継がず(=解除として扱う)、カウンタもリセットする
carry_forward_previous_entry() {
    local session="$1"
    local -r max_resolve_failures=12 # 5 分間隔の cron で概ね 1 時間相当
    local failure_count

    failure_count=$(($(get_resolve_failure_count "$session") + 1))
    if [ "$failure_count" -ge "$max_resolve_failures" ]; then
        set_resolve_failure_count "$session" 0
        return
    fi
    set_resolve_failure_count "$session" "$failure_count"

    awk -F'\t' -v s="$session" '$1 == s { print $1"\t"$2"\t"$3"\t"$4"\t0\t"$6; exit }' "$STATE_FILE" >> "$NEW_STATE_FILE"
}

# 現在リミット中の tmux セッション一覧を検出し、$NEW_STATE_FILE に書き出す。
# 各行は "<session>\t<cwd>\t<reset_epoch>\t<reset_text>\t<confirmed:0|1>\t<turn_id>" の形式。
# confirmed=1 は今回のポーリングで実際に is_limited=1 と確認できたことを示し、
# confirmed=0 は特定失敗・判定不能により前回の記録を引き継いだだけであることを示す
# (呼び出し元は confirmed=1 の場合のみ resume_session を試みる)。
# tmux セッション一覧の取得自体に失敗した場合は終了コード 1 を返し、
# $NEW_STATE_FILE を書き換えない(呼び出し元は前回の STATE_FILE をそのまま使う)
detect_limited_sessions() {
    local sessions list_exit jsonl status_line status reset_epoch reset_text turn_id cwd session

    sessions=$(tmux list-sessions -F "#{session_name}" 2>/dev/null)
    list_exit=$?
    if [ "$list_exit" -ne 0 ] && [ -s "$STATE_FILE" ]; then
        # tmux セッション一覧の取得自体に失敗しており(cron 環境の TMUX_TMPDIR 不一致等)、
        # かつ前回追跡中のセッションが存在した場合、実際にセッションが消えたのか
        # 単なる列挙失敗なのか区別できない。誤って全セッションを「解除」と
        # 判定してしまわないよう、この回の検出結果は使わない
        return 1
    fi

    : > "$NEW_STATE_FILE"

    for session in $sessions; do
        jsonl=$(resolve_rollout_path "$session")
        if [ -z "$jsonl" ]; then
            # fd 走査は他ツール実行中のプロセス入れ替わり等で一時的に失敗しうる
            carry_forward_previous_entry "$session"
            continue
        fi

        status_line=$(check_limit_status "$jsonl")
        IFS=$'\t' read -r status reset_epoch reset_text turn_id <<< "$status_line"
        if [ "$status" = "2" ]; then
            # jq がこのポーリングの走査対象範囲を解析できなかった(判定不能)。
            # 「リミットなし」と誤判定すると解除通知が誤って飛んでしまうため、
            # resolve 失敗と同様に前回の記録を引き継ぐ
            carry_forward_previous_entry "$session"
            continue
        fi
        [ "$status" = "1" ] || { set_resolve_failure_count "$session" 0; continue; }
        set_resolve_failure_count "$session" 0

        cwd=$(tmux display-message -t "${session}:" -p '#{pane_current_path}' 2>/dev/null || echo "unknown")
        printf '%s\t%s\t%s\t%s\t1\t%s\n' "$session" "$cwd" "$reset_epoch" "$reset_text" "$turn_id" >> "$NEW_STATE_FILE"
    done

    sort -u "$NEW_STATE_FILE" -o "$NEW_STATE_FILE"
    return 0
}

# reset_epoch を JST の可読文字列に変換する。数値でない・空の場合は "-" を返す
format_jst() {
    local epoch="$1"
    [[ "$epoch" =~ ^[0-9]+$ ]] || { echo "-"; return; }
    TZ="Asia/Tokyo" date -d "@${epoch}" "+%Y-%m-%d %H:%M JST" 2>/dev/null || echo "-"
}

# Discord Embed 通知を送信する。HTTP レスポンスが 2xx でない場合は失敗として
# 終了コード 1 を返す(呼び出し元は通知の再送要否を判断できる)
send_discord() {
    local title="$1" description="$2" color="$3"
    local content="" http_code payload

    [ -n "$MENTION_USER_ID" ] && content="<@${MENTION_USER_ID}>"

    payload=$(jq -n \
        --arg content "$content" \
        --arg title "$title" \
        --arg description "$description" \
        --argjson color "$color" \
        '{content: $content, embeds: [{title: $title, description: $description, color: $color}]}'
    )

    http_code=$(curl -s -o /dev/null -w '%{http_code}' -H "Content-Type: application/json" -X POST -d "$payload" "$DISCORD_WEBHOOK_URL")
    if [[ ! "$http_code" =~ ^2 ]]; then
        echo "send_discord: Discord notification failed (HTTP ${http_code:-unknown})" >&2
        return 1
    fi
}

# 「リミット到達」通知を送信済みかどうかを reset_epoch 単位で記録するファイルのパス。
# STATE_FILE への記録は通知成否と無関係に確定してしまうため、送信失敗を独立に
# 追跡し、次回ポーリングでの再送を可能にする
notified_marker_file() {
    echo "$HOME/.codex/scripts/limit-unlocked/data/notified_limited.txt"
}

already_notified_for() {
    local session="$1" reset_epoch="$2" file recorded
    file=$(notified_marker_file)
    [ -f "$file" ] || return 1
    recorded=$(awk -F'\t' -v s="$session" '$1 == s { print $2; exit }' "$file")
    [ -n "$recorded" ] && [ "$recorded" = "$reset_epoch" ]
}

record_notified_for() {
    local session="$1" reset_epoch="$2" file tmp_file
    file=$(notified_marker_file)
    mkdir -p "$(dirname "$file")"
    touch "$file"
    tmp_file="${file}.tmp.$$"
    { awk -F'\t' -v s="$session" '$1 != s { print }' "$file"; printf '%s\t%s\n' "$session" "$reset_epoch"; } > "$tmp_file"
    mv "$tmp_file" "$file"
}

# resume_session を同一キー(resume_key_for の結果、通常は turn_id)に対して
# 再送していないかを記録するファイルのパス。Codex の check_limit_status は
# event_msg/task_complete のみを見ており、送信した再開メッセージ自体は
# task_complete を発生させないため、ターン完了までは最後の task_complete が
# usage_limit_exceeded のまま残り続ける。この記録がないと、ターン完了までの間
# 5 分ごとの cron 実行のたびに再開キーを送り続けてしまう
resumed_marker_file() {
    echo "$HOME/.codex/scripts/limit-unlocked/data/resumed_sessions.txt"
}

already_resumed_for() {
    local session="$1" reset_epoch="$2" file recorded
    file=$(resumed_marker_file)
    [ -f "$file" ] || return 1
    recorded=$(awk -F'\t' -v s="$session" '$1 == s { print $2; exit }' "$file")
    [ -n "$recorded" ] && [ "$recorded" = "$reset_epoch" ]
}

record_resumed_for() {
    local session="$1" reset_epoch="$2" file tmp_file
    file=$(resumed_marker_file)
    mkdir -p "$(dirname "$file")"
    touch "$file"
    tmp_file="${file}.tmp.$$"
    { awk -F'\t' -v s="$session" '$1 != s { print }' "$file"; printf '%s\t%s\n' "$session" "$reset_epoch"; } > "$tmp_file"
    mv "$tmp_file" "$file"
}

# rollout が Goal 付きスレッドかどうかを確認する。実運用で観測したところ、Codex は
# usage limit 到達時に thread_goal_updated を status=usageLimited で記録するとは
# 限らず(この診断で status が一度も "active" 以外にならないまま limit に到達した
# 実例が確認された)、一方で Goal 付きスレッドが limit から復帰する際は通常メッセージ
# では TUI 側の Goal 状態が解除されず /goal resume が必須だったため、
# status の値ではなく thread_goal_updated が一度でも記録されているか(=このスレッドが
# Goal 付きかどうか)だけを見る。tail 等で走査範囲を絞ると、開始直後の
# thread_goal_updated が長時間セッションの末尾から外れて見落とされるため、
# ファイル全体を対象にする
goal_resume_required() {
    local jsonl="$1" goal_events

    [ -f "$jsonl" ] || return 1

    if ! goal_events=$(
        jq -r 'select(.type == "event_msg" and .payload.type == "thread_goal_updated") | 1' "$jsonl" 2>/dev/null
    ); then
        return 1
    fi

    [ -n "$goal_events" ]
}

# 指定した tmux セッションに再開入力を送る。
# ウィンドウ/ペイン番号を固定せずセッション名のみを指定し、tmux の base-index 設定
# (0 始まりとは限らない)に依存せず常にアクティブなウィンドウ・ペインへ送信する
#
# Codex はリミット到達後もブロッキングメニューを表示せず(Claude Code の
# "What do you want to do?" 相当の挙動はない)、入力プロンプトはそのまま
# 使用可能であるため、Escape でメニューを閉じる処理は不要
resume_session() {
    local session="$1" jsonl resume_input

    resume_input="<system-reminder>Codex's rate limit has been lifted. Continue the task you were working on before the interruption.</system-reminder>"
    jsonl=$(resolve_rollout_path "$session" 2>/dev/null || true)
    if [ -n "$jsonl" ] && goal_resume_required "$jsonl"; then
        resume_input="/goal resume"
    fi

    # "0" のような裸の数字セッション名は tmux に「未指定」とみなされ
    # 現在のセッションへフォールバックしてしまうため、末尾に ":" を付けて
    # セッション名指定であることを明示する(display-message と同様の理由)
    tmux send-keys -t "${session}:" "$resume_input"
    sleep 1
    tmux send-keys -t "${session}:" Enter
}

# reset_epoch 到達直後は解除がまだ反映されていないことがあるため、
# 一定時間 (RESUME_DELAY_SECONDS) 経過してから再開する
RESUME_DELAY_SECONDS=60

# reset_epoch から RESUME_DELAY_SECONDS 経過しているか判定する
resume_due() {
    local reset_epoch="$1" now="$2"
    [ "$now" -ge "$((reset_epoch + RESUME_DELAY_SECONDS))" ]
}

# resume の重複排除キーを決定する。turn_id は task_complete イベントごとに一意なため、
# これをキーにすると reset_epoch の推定が外れて resume に失敗した場合でも、
# 次に発生する新しい turn_id を「別の失敗」として検知し再試行できる。
# turn_id が取得できない(空/"-")場合のみ、従来通り reset_epoch にフォールバックする
resume_key_for() {
    local reset_epoch="$1" turn_id="$2" key
    key="${turn_id:--}"
    [ "$key" != "-" ] || key="$reset_epoch"
    printf '%s\n' "$key"
}

# セッション名が対象ファイルに存在するか確認する
session_recorded_in() {
    local session="$1" file="$2"
    awk -F'\t' -v s="$session" '$1 == s { found=1 } END { exit !found }' "$file" 2>/dev/null
}

# メイン処理: このファイルが直接実行された場合のみ実行する。
# テスト等から source されたとき(BASH_SOURCE がスクリプト自身と一致しない)は
# 関数定義のみを提供し、mkdir・Discord 通知・tmux 操作などの副作用は起こさない。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

    mkdir -p "$HOME/.codex/scripts/limit-unlocked/data"
    STATE_FILE="$HOME/.codex/scripts/limit-unlocked/data/limited_sessions.txt"
    NEW_STATE_FILE="${STATE_FILE}.new"
    touch "$STATE_FILE"

    # shellcheck source=/dev/null
    source ./.env

    if detect_limited_sessions; then
        now=$(date +%s)

        # 新規にリミットへ到達したセッションを通知する
        while IFS=$'\t' read -r session cwd reset_epoch reset_text confirmed turn_id; do
            [ -n "$session" ] || continue
            if ! already_notified_for "$session" "$reset_epoch"; then
                echo "Limit detected: $session ($cwd)"
                description="${cwd} (session: ${session}) が利用制限に達しました。"
                description="${description}"$'\n'"再開予定: $(format_jst "$reset_epoch")"
                [ -n "$reset_text" ] && [ "$reset_text" != "-" ] && description="${description}"$'\n'"${reset_text}"
                if send_discord \
                    "Codex CLI のリミット到達" \
                    "$description" \
                    15158332 # 赤系色
                then
                    record_notified_for "$session" "$reset_epoch"
                fi
            fi

            # confirmed=1(このポーリングで実際にリミット中と確認できた)場合のみ
            # 再開を試みる。confirmed=0 の引き継ぎ行は未検証のため対象にしない
            if [ "$confirmed" = "1" ] && [[ "$reset_epoch" =~ ^[0-9]+$ ]] && resume_due "$reset_epoch" "$now"; then
                resume_key=$(resume_key_for "$reset_epoch" "$turn_id")
                if ! already_resumed_for "$session" "$resume_key"; then
                    echo "Resuming: $session ($cwd)"
                    resume_session "$session"
                    record_resumed_for "$session" "$resume_key"
                fi
            fi
        done < "$NEW_STATE_FILE"

        # リミットが解除された(前回は記録されていたが今回は検出されなかった)セッションを通知する
        while IFS=$'\t' read -r session cwd reset_epoch reset_text confirmed turn_id; do
            [ -n "$session" ] || continue
            session_recorded_in "$session" "$NEW_STATE_FILE" && continue # まだリミット中

            if tmux has-session -t "${session}:" 2>/dev/null; then
                echo "Limit unlocked: $session ($cwd)"
                send_discord \
                    "Codex CLI のリミット解除" \
                    "${cwd} (session: ${session}) のリミットが解除されました。" \
                    5814783 # 青系色
            fi
        done < "$STATE_FILE"

        mv "$NEW_STATE_FILE" "$STATE_FILE"
    else
        echo "detect_limited_sessions: tmux session enumeration appears unreliable this run; preserving previous state" >&2
    fi
fi
