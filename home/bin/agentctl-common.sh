#!/bin/bash
# agentctl 共通ライブラリ。state/runtime identity/locking/tmux ownership/policy を扱う。
# NOTE: このファイルは git/gh を一切呼び出さない (keeper は Git lifecycle を所有しない)。

# --- パス解決 -----------------------------------------------------------

agentctl_state_home() {
  echo "${XDG_STATE_HOME:-$HOME/.local/state}/agentctl"
}

agentctl_root_dir() {
  agentctl_state_home
}

agentctl_runtimes_dir() {
  echo "$(agentctl_root_dir)/runtimes"
}

agentctl_locks_dir() {
  echo "$(agentctl_root_dir)/locks"
}

agentctl_runtime_dir() {
  echo "$(agentctl_runtimes_dir)/$1"
}

agentctl_ensure_root() {
  local root
  root=$(agentctl_root_dir)
  mkdir -p "$root" "$(agentctl_runtimes_dir)" "$(agentctl_locks_dir)"
  chmod 0700 "$root" "$(agentctl_runtimes_dir)" "$(agentctl_locks_dir)"
}

# tmux は全呼び出しをこの wrapper 経由にする。
# bash の {fd} 自動割当は close-on-exec が立たない (実測確認済み)。
# tmux server に session が無い状態は既定 exit-empty により自己終了するため、
# `new-session` で初めて daemonize が起きた場合、その時点で lock fd が
# 開いていると server 自身が fd を継承し flock を永久に保持してしまう。
# サブシェルで自 lock fd を閉じてから tmux を呼ぶことで継承を防ぐ。
agentctl_tmux() {
  (
    [ -z "${AGENTCTL_LOCK_FD:-}" ] || eval "exec ${AGENTCTL_LOCK_FD}<&-" 2>/dev/null
    [ -z "${AGENTCTL_DEPLOY_LOCK_FD:-}" ] || eval "exec ${AGENTCTL_DEPLOY_LOCK_FD}<&-" 2>/dev/null
    command tmux "$@"
  )
}

# tmux pipe-pane で pane の生バイト出力を raw_file (dir/.backend-ready-probe.raw)
# へ監視する。bracketed paste 有効化シーケンス (\e[?2004h) のような制御
# シーケンスは capture-pane の描画済みスクリーンには現れないため、これの
# 「一度でも出現したか」の検出にのみ raw byte stream を使う (quiescence の
# 判定には使わない: pipe-pane の配送は高負荷時に ~1KB/1秒超まとめて遅延
# することが実測で確認されており、短時間の無変化を「静止」と誤検知する)。
# pipe-pane は書き込み先コマンドへのデータを内部バッファリングしており、
# 出力量が小さいと pipe を張ったまま待ち続けても raw_file に一切反映されない
# ことが実測で確認された (バッファは pipe-pane を無効化した瞬間にまとめて
# flush される)。そのため毎 poll ごとに無効化/再有効化して強制的に flush する。
agentctl_wait_bracketed_paste_armed() {
  local pane="$1" dir="$2" timeout="$3"
  local poll_interval="${AGENTCTL_READY_POLL_SECONDS:-0.3}"
  local raw_file="$dir/.backend-ready-probe.raw"
  : >"$raw_file"
  # backend 起動直後の最初の書き込み window を取りこぼさないよう、poll loop に
  # 入る前に一度 attach しておく (loop 内の sleep の後で初めて attach すると、
  # backend が起動直後に一度だけ出す escape sequence を loop 開始前に逃す)。
  agentctl_tmux pipe-pane -t "$pane" -o "cat >>'$raw_file'"

  local elapsed=0 found=1
  while awk -v e="$elapsed" -v d="$timeout" 'BEGIN{exit !(e<d)}'; do
    sleep "$poll_interval"
    agentctl_tmux pipe-pane -t "$pane" >/dev/null 2>&1
    agentctl_tmux pipe-pane -t "$pane" -o "cat >>'$raw_file'"
    if grep -qaF $'\x1b[?2004h' "$raw_file" 2>/dev/null; then
      found=0
      break
    fi
    elapsed=$(awk -v e="$elapsed" -v p="$poll_interval" 'BEGIN{print e+p}')
  done
  agentctl_tmux pipe-pane -t "$pane" >/dev/null 2>&1
  rm -f "$raw_file"
  return "$found"
}

# tmux capture-pane が返す現在のスクリーン内容 (tmux 自身が直接保持している
# 状態) を snapshot として比較し、一定「時間」(poll 回数ではなく wall-clock
# 秒数) 無変化が続くまで待つ。pipe-pane の非同期配送チャネルを経由しない
# ため、上記の配送遅延バッチングの影響を受けない (実測で capture-pane は
# 描画の都度リアルタイムに追従することを確認済み)。特定 UI 文字列には一切
# 依存しない。runtime state/reconcile はこの関数を使わず marker/pid token
# のみで判定する (この待受けは publication/submit の一度きりの barrier に
# 限定)。成功時 0、timeout 時 1 を返す (die しない; fail-closed の判断は
# 呼び出し元が行う)。
agentctl_wait_screen_quiet() {
  local pane="$1" timeout="$2"
  local quiet_duration="${3:-2}"
  local poll_interval="${AGENTCTL_READY_POLL_SECONDS:-0.3}"

  local elapsed=0 prev_snap="" cur_snap quiet_since=-1 quiet_elapsed
  while awk -v e="$elapsed" -v d="$timeout" 'BEGIN{exit !(e<d)}'; do
    cur_snap=$(agentctl_tmux capture-pane -p -t "$pane" 2>/dev/null)
    if [ "$cur_snap" = "$prev_snap" ] && [ -n "$cur_snap" ]; then
      [ "$quiet_since" = "-1" ] && quiet_since="$elapsed"
      quiet_elapsed=$(awk -v e="$elapsed" -v s="$quiet_since" 'BEGIN{print e-s}')
      if awk -v qe="$quiet_elapsed" -v qd="$quiet_duration" 'BEGIN{exit !(qe>=qd)}'; then
        return 0
      fi
    else
      quiet_since=-1
    fi
    prev_snap="$cur_snap"
    sleep "$poll_interval"
    elapsed=$(awk -v e="$elapsed" -v p="$poll_interval" 'BEGIN{print e+p}')
  done
  return 1
}

# 起動直後に paste+Enter すると、実 backend の readline がまだ armed でない
# 間に Enter だけ失われ (byte は届くが submit されない)、後続 steer の
# paste+Enter が未 submit の initial mission と連結されて誤実行される race
# が実測で確認された (単純 sleep 追加では backend 起動時間のばらつきに対し
# 再現性がない)。mission を届ける前に、readline が armed かつ画面遷移が
# 収まるまで待つ。timeout は fail-closed で die する。
agentctl_wait_backend_ready() {
  local backend="$1" pane="$2" dir="$3"
  [ "$backend" = "fake" ] && return 0
  local armed_timeout="${AGENTCTL_READY_TIMEOUT_SECONDS:-30}"
  local settle_timeout="${AGENTCTL_READY_SETTLE_TIMEOUT_SECONDS:-15}"
  local quiet_duration="${AGENTCTL_READY_QUIET_SECONDS:-2}"
  agentctl_wait_bracketed_paste_armed "$pane" "$dir" "$armed_timeout" \
    || agentctl_die "backend '$backend' did not become ready to receive input within ${armed_timeout}s"
  agentctl_wait_screen_quiet "$pane" "$settle_timeout" "$quiet_duration" \
    || agentctl_die "backend '$backend' screen did not settle after becoming ready within ${settle_timeout}s"
}

# paste-buffer は pty へ本文を投入するだけで、実 TUI backend (Claude/Codex)
# の入力欄には残ったまま実行されない (実測確認済み: 手動 Enter 1 回で即実行)。
# 長文 multiline paste は TUI 側が "[Pasted text #N +M lines]" のような
# placeholder へ再描画するまでの短い非同期処理を挟むため、paste 直後に
# 即 Enter すると (readline は既に armed でも) その Enter が同様に失われる
# ことが実測で確認された。send-keys Enter の前に画面が再び静止するまで
# 待つ。fake backend は tee sink がバイト受信をそのまま観測するだけで
# submit 概念が無いため、byte-exact assertion を壊さないよう何もしない。
agentctl_submit_paste() {
  local backend="$1" pane="$2"
  [ "$backend" = "fake" ] && return 0
  local timeout="${AGENTCTL_SUBMIT_SETTLE_TIMEOUT_SECONDS:-20}"
  local quiet_duration="${AGENTCTL_SUBMIT_SETTLE_QUIET_SECONDS:-2}"
  # timeout 時は screen が静止しなかっただけで、Enter 未送信/送信済みのどちらも
  # あり得る (paste 自体は byte として届いている可能性がある)。acceptance を
  # "failed" と断定できず "unknown" として fail closed する。呼び出し元は
  # この状態から自動再送してはならない (二重実行/競合実行を避けるため)。
  agentctl_wait_screen_quiet "$pane" "$timeout" "$quiet_duration" \
    || agentctl_die "backend '$backend' pane did not settle after paste within ${timeout}s (acceptance unknown; do not resend automatically)"
  agentctl_tmux send-keys -t "$pane" Enter
}

# --- 汎用ヘルパ -----------------------------------------------------------

agentctl_die() {
  echo "agentctl: error: $*" >&2
  exit 1
}

agentctl_gen_runtime_id() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    # ponytail: uuidgen 非搭載環境向けの最小フォールバック。より厳密な乱数性が要る場合は uuidgen 導入で置換。
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

# 指定 mode で atomic write する。本文は stdin から受け取り、argv/state には残さない。
# usage: agentctl_atomic_write <dest_path> <mode>  (stdin=content)
agentctl_atomic_write() {
  local dest="$1" mode="$2" tmp
  tmp="${dest}.tmp.$$"
  umask 077
  cat >"$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dest"
}

# best-effort file/directory fsync (durability の補強であり、TOCTOU 対策の本体は
# agentctl_secure_create の O_EXCL 相当 + atomic rename 側にある)。python3 が
# 使えない環境では何もしない。
agentctl_fsync_path() {
  local path="$1" flag="$2"
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c '
import os, sys
path, is_dir = sys.argv[1], sys.argv[2] == "dir"
fd = os.open(path, os.O_DIRECTORY if is_dir else os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
' "$path" "$flag" 2>/dev/null || true
}

# dest (symlink を含む) が既に存在する場合は追従/上書きせず fail closed する
# 新規ファイル作成。事前に仕込まれた symlink 経由の差し替えを避けるため
# O_EXCL 相当 (noclobber) で作成し、fsync 後に atomic rename で publish する。
# 呼び出し元は、以後 dest を一切変更しない (一操作専用ファイルとして扱う)
# ことで作成後〜読み取りまでの TOCTOU を避ける。本文は stdin から受け取る。
# usage: agentctl_secure_create <dest_path> <mode>  (stdin=content)
agentctl_secure_create() {
  local dest="$1" mode="$2" tmp
  tmp="${dest}.tmp.$$"
  ( set -C; umask 077; cat >"$tmp" ) \
    || { rm -f "$tmp"; agentctl_die "failed to create temp file for secure create: $tmp"; }
  chmod "$mode" "$tmp"
  agentctl_fsync_path "$tmp" file
  if ! mv -n -- "$tmp" "$dest"; then
    rm -f "$tmp"
    agentctl_die "secure create publish failed: $dest"
  fi
  if [ -e "$tmp" ]; then
    # mv -n は dest が既存の場合 tmp を残したまま exit 0 で no-op するため、
    # tmp が消えていなければ衝突 (dest 既存) とみなして fail closed する。
    rm -f "$tmp"
    agentctl_die "secure create destination already exists (refusing to overwrite): $dest"
  fi
  agentctl_fsync_path "$(dirname "$dest")" dir
}

agentctl_gen_operation_id() {
  agentctl_gen_runtime_id
}

# --- operation event log -----------------------------------------------------------
# mission/steer/resume の各 delivery 操作について、本文を一切含まない
# メタデータのみ (operation_id/timestamp/runtime_id/operation/transport/
# body の sha256/submission と acceptance の結果) を append-only の
# events.jsonl (0600) に記録する。本文そのものが漏れると argv/history を
# 避けてきた既存対策が意味を成さなくなるため、payload 文字列は引数として
# 一切受け取らない (呼び出し元は sha256 だけを渡す)。

# usage: agentctl_log_operation_event <dir> <operation_id> <runtime_id> <operation> <transport> <body_sha256> <submission> <acceptance>
# submission: submitted|failed。acceptance: unknown|accepted (screen heuristic からは
# 絶対に "accepted" を記録しない。native transport が turn ID 等の確証を得られる
# 場合にのみ将来 "accepted" を渡せるようにする、現行 fallback は常に "unknown")。
agentctl_log_operation_event() {
  local dir="$1" operation_id="$2" runtime_id="$3" operation="$4" transport="$5" body_sha256="$6" submission="$7" acceptance="$8"
  local events_file="$dir/events.jsonl" now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  [ -e "$events_file" ] || ( umask 077; : >"$events_file" )
  jq -n -c \
    --arg operation_id "$operation_id" --arg timestamp "$now" --arg runtime_id "$runtime_id" \
    --arg operation "$operation" --arg transport "$transport" --arg body_sha256 "$body_sha256" \
    --arg submission "$submission" --arg acceptance "$acceptance" \
    '{operation_id:$operation_id, timestamp:$timestamp, runtime_id:$runtime_id, operation:$operation,
      transport:$transport, body_sha256:$body_sha256, result:{submission:$submission, acceptance:$acceptance}}' \
    >>"$events_file"
}

# body_path 全文を pane へ届ける。fake/claude/claude-work は本文をそのまま
# paste する (byte-exact, 既存動作を維持)。codex だけは、pane 高さを超える
# 長文 multiline paste で TUI 側の paste-end 追跡が壊れ Enter が届かない
# 不具合が実測されたため、本文を直接 paste せず operation-specific secure
# copy への絶対 path + sha256 を示す短い固定 bootstrap を paste する
# (agentctl-backend-codex.sh 側で用意する)。
#
# 届け終えた後、本文を含まないメタデータだけを events.jsonl (0600) に記録する。
# agentctl_submit_paste は screen-settle timeout で die するが、die した時点の
# acceptance は「失敗」と断定できない (Enter が届いたか不明) ため、die の前に
# サブシェルで実行して exit code/stderr を捕まえ、"failed"/"unknown" として
# 記録してから同じメッセージで die し直す (real backend の paste/submit 挙動
# 自体はサブシェル化しても変わらない)。
# usage: agentctl_deliver_body <backend> <pane> <dir> <body_path> <runtime_id> <operation>
agentctl_deliver_body() {
  local backend="$1" pane="$2" dir="$3" body_path="$4" runtime_id="$5" operation="$6"
  local bufname="agentctl-deliver-$$"
  local transport="tui-paste"
  if [ "$backend" = "codex" ]; then
    local op_file sha
    op_file=$(agentctl_backend_codex_prepare_operation_file "$dir" "$body_path")
    sha=$(sha256sum "$op_file" | awk '{print $1}')
    agentctl_backend_codex_bootstrap_message "$op_file" "$sha" \
      | agentctl_tmux load-buffer -b "$bufname" -
    transport="codex-bootstrap-file"
  elif [ "$backend" = "fake" ]; then
    agentctl_tmux load-buffer -b "$bufname" -- "$body_path"
    transport="fake-sink"
  else
    agentctl_tmux load-buffer -b "$bufname" -- "$body_path"
  fi
  agentctl_tmux paste-buffer -r -b "$bufname" -d -t "$pane"

  local body_sha operation_id submit_err
  body_sha=$(sha256sum "$body_path" | awk '{print $1}')
  operation_id=$(agentctl_gen_operation_id)
  submit_err=$(mktemp)
  if ( agentctl_submit_paste "$backend" "$pane" ) 2>"$submit_err"; then
    agentctl_log_operation_event "$dir" "$operation_id" "$runtime_id" "$operation" "$transport" "$body_sha" "submitted" "unknown"
    rm -f "$submit_err"
  else
    agentctl_log_operation_event "$dir" "$operation_id" "$runtime_id" "$operation" "$transport" "$body_sha" "failed" "unknown"
    cat "$submit_err" >&2
    rm -f "$submit_err"
    exit 1
  fi
}

# --- policy schema 検証 -----------------------------------------------------------

AGENTCTL_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 標準出力に canonical policy JSON を返す。不正なら stderr にエラー一覧を出して exit 1 (fail closed)。
agentctl_validate_policy_file() {
  local policy_file="$1" result ok
  [ -f "$policy_file" ] || agentctl_die "policy file not found: $policy_file"
  if ! jq -e . "$policy_file" >/dev/null 2>&1; then
    agentctl_die "policy file is not valid JSON: $policy_file"
  fi
  result=$(jq -f "$AGENTCTL_LIBDIR/agentctl-policy-validate.jq" "$policy_file") || agentctl_die "policy validation crashed"
  ok=$(echo "$result" | jq -r '.ok')
  if [ "$ok" != "true" ]; then
    echo "agentctl: policy validation failed:" >&2
    echo "$result" | jq -r '.errors[]' | sed 's/^/  - /' >&2
    exit 1
  fi
  echo "$result" | jq -c '.policy'
}

agentctl_policy_digest() {
  # canonical JSON (stdin) の sha256 digest。
  sha256sum | awk '{print "sha256:" $1}'
}

# --- per-name ロック -----------------------------------------------------------

# usage: agentctl_with_name_lock <name> <func> [args...]
agentctl_with_name_lock() {
  local name="$1"; shift
  local lockfile
  lockfile="$(agentctl_locks_dir)/${name}.lock"
  (
    exec {AGENTCTL_LOCK_FD}<>"$lockfile"
    flock -x "$AGENTCTL_LOCK_FD"
    "$@"
  )
}

# --- deployment global lock (shared: publication / exclusive: rollback) --------

agentctl_deployment_lock_path() {
  echo "$(agentctl_locks_dir)/deployment.lock"
}

# 呼び出し元の現在シェルで fd を保持したいので副シェルにしない。
# tmux server は agentctl_ensure_root で事前起動済みである前提のため、
# 以降の tmux 呼び出しは既存 server への短命クライアント接続のみとなり、
# lock fd が daemon プロセスへ継承されたまま残ることはない。
agentctl_acquire_deployment_lock_shared() {
  local lockfile
  lockfile="$(agentctl_deployment_lock_path)"
  exec {AGENTCTL_DEPLOY_LOCK_FD}<>"$lockfile"
  flock -s "$AGENTCTL_DEPLOY_LOCK_FD"
}

agentctl_acquire_deployment_lock_exclusive() {
  local lockfile
  lockfile="$(agentctl_deployment_lock_path)"
  exec {AGENTCTL_DEPLOY_LOCK_FD}<>"$lockfile"
  flock -x "$AGENTCTL_DEPLOY_LOCK_FD"
}

agentctl_release_deployment_lock() {
  [ -n "${AGENTCTL_DEPLOY_LOCK_FD:-}" ] || return 0
  eval "exec ${AGENTCTL_DEPLOY_LOCK_FD}<&-"
  unset AGENTCTL_DEPLOY_LOCK_FD
}

# --- fault injection (テスト専用) -----------------------------------------------------------

# AGENTCTL_TEST_FAULT_STAGE に一致したら、そのステージで即座に exit する。
# 本番運用ではこの環境変数は設定されない。
agentctl_maybe_fault() {
  [ "${AGENTCTL_TEST_FAULT_STAGE:-}" = "$1" ] || return 0
  echo "agentctl: [test] injected fault at stage: $1" >&2
  exit 90
}

# --- tmux ヘルパ -----------------------------------------------------------

agentctl_tmux_session() {
  echo "agentctl-$1"
}

agentctl_tmux_has_session() {
  agentctl_tmux has-session -t "=$1" 2>/dev/null
}

agentctl_tmux_pane_id() {
  # $1 = session name。window base-index がユーザ tmux.conf で 0 以外の場合があるため
  # ":0" を決め打ちせず、セッションのアクティブ pane を解決する。
  agentctl_tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null
}

agentctl_tmux_pane_pid() {
  agentctl_tmux display-message -p -t "$1" '#{pane_pid}' 2>/dev/null
}

agentctl_tmux_pane_dead() {
  agentctl_tmux display-message -p -t "$1" '#{pane_dead}' 2>/dev/null
}

agentctl_tmux_pane_dead_status() {
  agentctl_tmux display-message -p -t "$1" '#{pane_dead_status}' 2>/dev/null
}

agentctl_tmux_set_marker() {
  local pane="$1" key="$2" value="$3"
  agentctl_tmux set-option -p -t "$pane" "@agentctl_${key}" "$value"
}

agentctl_tmux_get_marker() {
  local pane="$1" key="$2"
  agentctl_tmux show-options -p -t "$pane" -v "@agentctl_${key}" 2>/dev/null
}

# --- PID fencing -----------------------------------------------------------

# PID 再利用を検出するための起動時刻トークン (/proc/PID/stat の22番目フィールド = starttime)。
agentctl_pid_start_token() {
  local pid="$1" stat
  [ -r "/proc/$pid/stat" ] || { echo ""; return; }
  stat=$(cat "/proc/$pid/stat" 2>/dev/null) || { echo ""; return; }
  # comm フィールドに空白/括弧が入り得るため、最後の ')' 以降でフィールド分割する。
  echo "$stat" | awk -F') ' '{print $2}' | awk '{print $20}'
}

# --- state I/O -----------------------------------------------------------

agentctl_state_file() {
  echo "$(agentctl_runtime_dir "$1")/state.json"
}

agentctl_read_state() {
  local f
  f=$(agentctl_state_file "$1")
  [ -f "$f" ] || return 1
  jq -c . "$f"
}

agentctl_write_state_json() {
  # usage: agentctl_write_state_json <name> <json-on-stdin>
  local name="$1" dir
  dir=$(agentctl_runtime_dir "$name")
  mkdir -p "$dir"
  chmod 0700 "$dir"
  agentctl_atomic_write "$(agentctl_state_file "$name")" 0600
}

# --- continuation manifest -----------------------------------------------------------
# keeper は manifest content を Git/merge 判定には使わない。agent-authored な
# checkpoint を resume/complete が読むための read-only index として扱う。

agentctl_manifest_file() {
  echo "$(agentctl_runtime_dir "$1")/manifest.json"
}

# start 時にだけ呼ぶ。resume は既存 manifest を上書きしない (継続 context を保つ)。
agentctl_write_initial_manifest() {
  local name="$1" cwd="$2" now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n --argjson schema_version 1 --arg worktree "$cwd" --arg now "$now" \
    '{schema_version:$schema_version, mission_status:"running", repository:null,
      worktree:$worktree, branch:null, base:null, head_sha:null, pr_url:null,
      last_checkpoint:null, updated_at:$now, terminal_reason:null}' \
    | agentctl_atomic_write "$(agentctl_manifest_file "$name")" 0600
}

# manifest を読み JSON を返す。壊れている/無い場合は fail closed (呼び出し側が exit する)。
agentctl_read_manifest() {
  local f
  f=$(agentctl_manifest_file "$1")
  [ -f "$f" ] || return 1
  jq -e -c . "$f" 2>/dev/null || return 1
}

# 生存中の pane から末尾ログを取る。pane が既に無い場合は空文字を返す
# (resume は前世代 session を kill する前にこれを呼ぶ必要がある)。
# usage: agentctl_capture_pane_tail <pane> <lines>
agentctl_capture_pane_tail() {
  local pane="$1" lines="$2"
  agentctl_tmux_has_session "$pane" || { echo ""; return 0; }
  agentctl_tmux capture-pane -p -J -t "$pane" -S "-$lines" 2>/dev/null || echo ""
}

# resume で新世代へ渡す read-only continuation bundle を構築する。
# manifest はあくまで前世代 agent の自己申告 (last_checkpoint 等) であり、
# クラッシュ・キャンセル・agent 自身の誤り等で実際の Git/PR 状態と乖離し
# 得るため、本文中で明示的に fresh agent へ実状態の再検証を指示する
# (spec: 継続 context を鵜呑みにせず実 Git/PR 状態を revalidate させる)。
# continuation context と元の mission は 1 本のファイルにまとめ、単一の
# paste+submit (1 turn) として届ける。paste+screen-settle には agent が
# turn を「完了した」ことを確認する barrier が無いため、2 回に分けて別々に
# 届けると 2 回目が 1 回目の turn 実行中の steer と区別できず、実 backend
# 上で衝突/混線し得る (fake backend の sink 連結ではこの race を検証できない)。
# mission_path は command substitution/関数引数の string 経由では渡さない。
# `$(cat file)` は末尾改行を無条件に落とすため、任意本文 (改行のみの行、
# 末尾複数改行、多バイト文字等) の byte-exact 契約に違反する。mission 本文
# だけは `cat -- <path>` でそのまま stdout へ streaming し、呼び出し元の
# パイプ (agentctl_atomic_write) までバイト単位で無加工に届ける。
# usage: agentctl_build_continuation_bundle <manifest_json> <log_tail> <policy_snapshot_path> <mission_path>
agentctl_build_continuation_bundle() {
  local manifest_json="$1" log_tail="$2" policy_snapshot_path="$3" mission_path="$4" policy_json
  policy_json=$(cat "$policy_snapshot_path")
  cat <<EOF
=== AGENTCTL CONTINUATION CONTEXT (read-only, resumed session) ===
A previous agent generation for this runtime exited or crashed before completing the mission. You are a fresh agent process with no memory of that generation. The data below is the predecessor's own last self-reported checkpoint and a tail of its terminal output; it is NOT verified and may be stale, incomplete, or wrong (the predecessor may have crashed mid-update, or misreported its own state).

Before taking any further action, you MUST independently re-check the actual current state of Git (branch, HEAD, working tree, any uncommitted changes) and, if a pull request is involved, its actual current status via gh/GitHub — do not assume the fields below are still true.

--- predecessor manifest (last self-reported checkpoint) ---
$manifest_json

--- predecessor runtime log (tail) ---
$log_tail

--- effective policy snapshot for this generation ---
$policy_json
=== END CONTINUATION CONTEXT ===

After revalidating the real Git/PR state above, continue the original mission below.

=== ORIGINAL MISSION ===
EOF
  cat -- "$mission_path"
}

# --- reconcile -----------------------------------------------------------

# name の実態を running|starting|stale|orphan|conflict|exited|absent のいずれかで返す。
# 画面スクレイピングをせず、tmux marker + pane 評価 + state file のみで判定する。
agentctl_reconcile() {
  local name="$1" session state_json marker_owner marker_runtime_id marker_name
  session=$(agentctl_tmux_session "$name")
  local has_tmux=0
  agentctl_tmux_has_session "$session" && has_tmux=1

  local has_state=0 state_runtime_id="" state_status="" state_pane_pid="" state_pane_pid_start=""
  if state_json=$(agentctl_read_state "$name"); then
    has_state=1
    state_runtime_id=$(echo "$state_json" | jq -r '.runtime_id')
    state_status=$(echo "$state_json" | jq -r '.status')
    state_pane_pid=$(echo "$state_json" | jq -r '.pane_pid')
    state_pane_pid_start=$(echo "$state_json" | jq -r '.pane_pid_start')
  fi

  if [ "$has_tmux" -eq 0 ]; then
    if [ "$has_state" -eq 1 ]; then
      echo "stale"
    else
      echo "absent"
    fi
    return 0
  fi

  # tmux セッションはある。pane marker を読む (pane_id ではなくセッション名で
  # アクティブ pane を解決する。base-index が 0 以外の tmux.conf でも安全)。
  local pane
  pane="$session"
  marker_owner=$(agentctl_tmux_get_marker "$pane" owner)
  marker_name=$(agentctl_tmux_get_marker "$pane" name)
  marker_runtime_id=$(agentctl_tmux_get_marker "$pane" runtime_id)

  if [ "$marker_owner" != "agentctl" ] || [ -z "$marker_runtime_id" ]; then
    # agentctl marker が不完全 = bootstrap 途中で終わった launcher crash 跡か、無関係セッション。
    if [ "$has_state" -eq 1 ]; then
      echo "conflict"
    else
      echo "orphan"
    fi
    return 0
  fi

  if [ "$has_state" -eq 0 ]; then
    echo "orphan"
    return 0
  fi

  if [ "$marker_runtime_id" != "$state_runtime_id" ] || [ "$marker_name" != "$name" ]; then
    echo "conflict"
    return 0
  fi

  local pane_dead
  pane_dead=$(agentctl_tmux_pane_dead "$pane")
  if [ "$pane_dead" = "1" ]; then
    echo "exited"
    return 0
  fi

  # PID 再利用フェンシング: 記録した pane_pid が生きていても起動時刻が違えば conflict。
  if [ -n "$state_pane_pid" ] && [ "$state_pane_pid" != "null" ] && [ -d "/proc/$state_pane_pid" ]; then
    local current_start
    current_start=$(agentctl_pid_start_token "$state_pane_pid")
    if [ -n "$current_start" ] && [ "$current_start" != "$state_pane_pid_start" ]; then
      echo "conflict"
      return 0
    fi
  fi

  if [ "$state_status" = "starting" ]; then
    echo "starting"
  else
    echo "running"
  fi
}
