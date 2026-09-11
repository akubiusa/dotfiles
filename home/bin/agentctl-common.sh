#!/bin/bash
# agentctl 共通ライブラリ。state/runtime identity/locking/tmux ownership/policy を扱う。
# NOTE: このファイルは git/gh を一切呼び出さない (keeper は Git lifecycle を所有しない)。

# hook wrapper から agentctl-common.sh 単独で source される経路でも runtime state
# schema を同じ値で検証できるよう、entrypoint 未定義時だけ既定値を与える。
AGENTCTL_SCHEMA_VERSION=${AGENTCTL_SCHEMA_VERSION:-1}

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

# Codex interactive TUI の hook subprocess は TUI 起動時に渡した session-local
# AGENTCTL_* env を継承しない。そのため Codex backend だけは、hook subprocess が
# 常に到達できる HOME 固定の小さな registry を bootstrap rendezvous として使う。
# runtime 本体の state root は XDG_STATE_HOME を尊重したままで、registry entry に
# absolute runtime_dir / policy path を保持する。HOME 固定なのは意図的であり、
# persistent Codex app-server 側の stale XDG_STATE_HOME に依存しないため。
agentctl_codex_hook_registry_dir() {
  echo "$HOME/.local/state/agentctl/codex-hook-bindings"
}

agentctl_codex_hook_pending_dir() {
  echo "$(agentctl_codex_hook_registry_dir)/pending"
}

agentctl_codex_hook_sessions_dir() {
  echo "$(agentctl_codex_hook_registry_dir)/sessions"
}

# arbitrary session_id/runtime_id を path component に直接使わない。
agentctl_codex_hook_key() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

agentctl_codex_hook_pending_file() {
  echo "$(agentctl_codex_hook_pending_dir)/$(agentctl_codex_hook_key "$1").json"
}

agentctl_codex_hook_session_file() {
  echo "$(agentctl_codex_hook_sessions_dir)/$(agentctl_codex_hook_key "$1").json"
}

agentctl_codex_hook_registry_ensure() {
  local root pending sessions
  root=$(agentctl_codex_hook_registry_dir)
  pending=$(agentctl_codex_hook_pending_dir)
  sessions=$(agentctl_codex_hook_sessions_dir)
  mkdir -p "$root" "$pending" "$sessions"
  chmod 0700 "$root" "$pending" "$sessions"
}

# usage: agentctl_codex_hook_publish_pending <name> <runtime_id> <runtime_dir>
#        <policy_snapshot> <policy_digest> <cwd>
# Sentinel hook が session_id を初回 binding するまでだけ存在する rendezvous record。
agentctl_codex_hook_publish_pending() {
  local name="$1" runtime_id="$2" runtime_dir="$3" policy_snapshot="$4" policy_digest="$5" cwd="$6"
  local dest
  agentctl_codex_hook_registry_ensure
  dest=$(agentctl_codex_hook_pending_file "$runtime_id")
  jq -n \
    --argjson schema_version "$AGENTCTL_SCHEMA_VERSION" \
    --arg runtime_id "$runtime_id" \
    --arg name "$name" \
    --arg runtime_dir "$runtime_dir" \
    --arg policy_snapshot "$policy_snapshot" \
    --arg policy_digest "$policy_digest" \
    --arg cwd "$cwd" \
    '{schema_version:$schema_version,runtime_id:$runtime_id,name:$name,backend:"codex",runtime_dir:$runtime_dir,policy_snapshot:$policy_snapshot,policy_digest:$policy_digest,cwd:$cwd}' \
    | agentctl_atomic_write "$dest" 0600
}

agentctl_codex_hook_remove_pending() {
  local runtime_id="$1"
  rm -f "$(agentctl_codex_hook_pending_file "$runtime_id")"
}

# runtime cleanup/failure 時に pending/session binding の両方を消す。
# session binding filename は session_id hash なので runtime_id から直接 path を
# 計算できず、中身を照合して該当 entry だけ削除する。
agentctl_codex_hook_remove_runtime_bindings() {
  local runtime_id="$1" file
  agentctl_codex_hook_remove_pending "$runtime_id"
  for file in "$(agentctl_codex_hook_sessions_dir)"/*.json; do
    [ -f "$file" ] || continue
    if jq -e --arg rid "$runtime_id" '.runtime_id == $rid' "$file" >/dev/null 2>&1; then
      rm -f "$file"
    fi
  done
}

# usage: agentctl_codex_hook_session_id_for_runtime <runtime_id> <runtime_dir>
# stdout: current generation に一意に bind 済みの Codex session_id。
# queue transport は tmux pane ではなく app-server session を直接指定するため、
# registry の runtime_id だけを信用せず state.json の generation/name/cwd/policy
# identity と binding 全体を再照合する。一致が 0 件/複数件/filename hash 不一致なら
# fail closed で何も返さない。
agentctl_codex_hook_session_id_for_runtime() {
  local runtime_id="$1" runtime_dir="$2" state_file state
  state_file="$runtime_dir/state.json"
  [ -f "$state_file" ] || return 1
  state=$(cat "$state_file" 2>/dev/null) || return 1

  local schema name backend state_runtime_id cwd policy_snapshot policy_digest status
  schema=$(echo "$state" | jq -r '.schema_version // empty' 2>/dev/null) || return 1
  name=$(echo "$state" | jq -r '.name // empty' 2>/dev/null) || return 1
  backend=$(echo "$state" | jq -r '.backend // empty' 2>/dev/null) || return 1
  state_runtime_id=$(echo "$state" | jq -r '.runtime_id // empty' 2>/dev/null) || return 1
  cwd=$(echo "$state" | jq -r '.cwd // empty' 2>/dev/null) || return 1
  policy_snapshot=$(echo "$state" | jq -r '.policy_snapshot_path // empty' 2>/dev/null) || return 1
  policy_digest=$(echo "$state" | jq -r '.policy_digest // empty' 2>/dev/null) || return 1
  status=$(echo "$state" | jq -r '.status // empty' 2>/dev/null) || return 1

  [ "$schema" = "$AGENTCTL_SCHEMA_VERSION" ] || return 1
  [ "$backend" = "codex" ] || return 1
  [ "$state_runtime_id" = "$runtime_id" ] || return 1
  [ "$status" = "running" ] || return 1
  [ -n "$name" ] && [ -n "$cwd" ] && [ -n "$policy_snapshot" ] && [ -n "$policy_digest" ] || return 1

  local sessions_dir file binding sid expected found="" count=0
  sessions_dir=$(agentctl_codex_hook_sessions_dir)
  for file in "$sessions_dir"/*.json; do
    [ -f "$file" ] || continue
    binding=$(cat "$file" 2>/dev/null) || return 1
    if echo "$binding" | jq -e \
      --argjson schema "$AGENTCTL_SCHEMA_VERSION" \
      --arg rid "$runtime_id" --arg name "$name" --arg dir "$runtime_dir" \
      --arg cwd "$cwd" --arg policy "$policy_snapshot" --arg digest "$policy_digest" \
      '.schema_version == $schema and .runtime_id == $rid and .name == $name and .backend == "codex"
       and .runtime_dir == $dir and .cwd == $cwd and .policy_snapshot == $policy
       and .policy_digest == $digest and (.session_id | type == "string" and length > 0)' \
      >/dev/null 2>&1; then
      sid=$(echo "$binding" | jq -r '.session_id') || return 1
      expected=$(agentctl_codex_hook_session_file "$sid")
      [ "$file" = "$expected" ] || return 1
      count=$((count + 1))
      found="$sid"
    fi
  done
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$found"
}

# usage: agentctl_validate_name <name>
# --name はディレクトリ名 (agentctl_runtime_dir)・tmux session 名
# (agentctl_tmux_session)・lock ファイル名 (agentctl_with_name_lock) に
# そのまま連結される。allowlist ([A-Za-z0-9_-]+) 一致のみを受理することで、
# 空文字/絶対パス/`.`/`..`/スラッシュ/バックスラッシュ/制御文字/空白を
# 個別に列挙して deny するのではなく、それら全てを構造的に排除する
# (quoting だけでは `../victim` のような traversal を防げない)。
agentctl_validate_name() {
  case "$1" in
    *[!A-Za-z0-9_-]*|"") agentctl_die "name must match [A-Za-z0-9_-]+: '$1'" ;;
  esac
}

agentctl_runtime_dir() {
  agentctl_validate_name "$1"
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


# Codex の短い bootstrap paste は operation file basename が操作ごとに一意である。
# busy turn 中は pane 全体が reasoning/status 描画で変化し続けるため quiescence を
# submit barrier にできない。capture-pane -J で wrapped line を結合した現在画面に
# 自分が paste した一意 marker が現れたことを、TUI が paste を描画済みで Enter を
# 受け取れる mechanical evidence とする。成功時 0、timeout 時 1。
agentctl_wait_screen_contains() {
  local pane="$1" marker="$2" timeout="$3"
  local poll_interval="${AGENTCTL_READY_POLL_SECONDS:-0.3}" elapsed=0 snap
  [ -n "$marker" ] || return 1
  while awk -v e="$elapsed" -v d="$timeout" 'BEGIN{exit !(e<d)}'; do
    snap=$(agentctl_tmux capture-pane -J -p -t "$pane" 2>/dev/null || true)
    if printf '%s\n' "$snap" | grep -Fq -- "$marker"; then
      return 0
    fi
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
    || agentctl_die --code 5 "backend '$backend' did not become ready to receive input within ${armed_timeout}s"
  agentctl_wait_screen_quiet "$pane" "$settle_timeout" "$quiet_duration" \
    || agentctl_die --code 5 "backend '$backend' screen did not settle after becoming ready within ${settle_timeout}s"
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
  local backend="$1" pane="$2" submit_marker="${3:-}"
  [ "$backend" = "fake" ] && return 0
  local timeout="${AGENTCTL_SUBMIT_SETTLE_TIMEOUT_SECONDS:-20}"

  if [ "$backend" = "codex" ]; then
    [ -n "$submit_marker" ] \
      || agentctl_die --code 5 "backend 'codex' submit marker is required (acceptance unknown; do not resend automatically)"
    agentctl_wait_screen_contains "$pane" "$submit_marker" "$timeout" \
      || agentctl_die --code 5 "backend 'codex' pasted bootstrap marker did not appear within ${timeout}s (acceptance unknown; do not resend automatically)"
    agentctl_tmux send-keys -t "$pane" Enter
    return 0
  fi

  local quiet_duration="${AGENTCTL_SUBMIT_SETTLE_QUIET_SECONDS:-2}"
  # timeout 時は screen が静止しなかっただけで、Enter 未送信/送信済みのどちらも
  # あり得る (paste 自体は byte として届いている可能性がある)。acceptance を
  # "failed" と断定できず "unknown" として fail closed する。呼び出し元は
  # この状態から自動再送してはならない (二重実行/競合実行を避けるため)。
  agentctl_wait_screen_quiet "$pane" "$timeout" "$quiet_duration" \
    || agentctl_die --code 5 "backend '$backend' pane did not settle after paste within ${timeout}s (acceptance unknown; do not resend automatically)"
  agentctl_tmux send-keys -t "$pane" Enter
}

# Fix #8: guard startup verification (mechanical proof)。settings JSON を
# 書いた/dispatcher を直接呼んだだけでは、実 backend process が実際に hook を
# load して PreToolUse を発火させる保証にならない。無害な sentinel command
# (実行されても no-op) を実 backend の turn 経由で走らせ、agentctl-policy-
# dispatcher.sh が本物の PreToolUse として認識して deny evidence を書くことを
# 観測して初めて guard が生きている証拠とする。fake backend は hook 機構自体を
# 持たないため呼び出し元で skip する。証拠が期限内に得られなければ 1 を返す
# (fail closed の判断/後始末は呼び出し元が行う)。
agentctl_guard_sentinel_command() {
  local runtime_id="$1"
  echo "true '#agentctl-guard-sentinel:$runtime_id'"
}

# usage: agentctl_verify_guard_sentinel <backend> <pane> <dir> <runtime_id>
agentctl_verify_guard_sentinel() {
  local backend="$1" pane="$2" dir="$3" runtime_id="$4"
  local evidence_file="$dir/guard-sentinel.json"
  rm -f "$evidence_file"

  local bufname="agentctl-sentinel-$$"
  if [ "$backend" = "codex" ]; then
    # Codex runtime では分類不能な exec tool call を fail closed で deny する。
    # sentinel 本文を operation file に隠すと、marker を含まない最初の
    # "read the file" exec が先に deny され、sentinel 自身へ到達できない。
    # sentinel は短い固定 1 行なので、複数行 paste の既知問題を避けつつ
    # marker 自体を最初の prompt に直接含める。
    printf 'System check (do not explain, just act): run exactly this shell command and nothing else: %s' \
      "$(agentctl_guard_sentinel_command "$runtime_id")" \
      | agentctl_tmux load-buffer -b "$bufname" -
  else
    local prompt_path
    prompt_path=$(mktemp)
    {
      echo "System check (do not explain, just act): run the Bash tool with exactly this command and nothing else:"
      agentctl_guard_sentinel_command "$runtime_id"
    } >"$prompt_path"
    agentctl_tmux load-buffer -b "$bufname" -- "$prompt_path"
    rm -f "$prompt_path"
  fi
  agentctl_tmux paste-buffer -r -b "$bufname" -d -t "$pane"

  local submit_timeout="${AGENTCTL_SENTINEL_SUBMIT_TIMEOUT_SECONDS:-20}"
  agentctl_wait_screen_quiet "$pane" "$submit_timeout" 2 || return 1
  agentctl_tmux send-keys -t "$pane" Enter

  local evidence_timeout="${AGENTCTL_GUARD_SENTINEL_TIMEOUT_SECONDS:-30}"
  local poll_interval="${AGENTCTL_READY_POLL_SECONDS:-0.3}"
  local elapsed=0
  while [ ! -f "$evidence_file" ]; do
    awk -v e="$elapsed" -v t="$evidence_timeout" 'BEGIN{exit !(e<t)}' || return 1
    sleep "$poll_interval"
    elapsed=$(awk -v e="$elapsed" -v p="$poll_interval" 'BEGIN{print e+p}')
  done

  local ev_runtime_id ev_decision
  ev_runtime_id=$(jq -r '.runtime_id // empty' "$evidence_file" 2>/dev/null)
  ev_decision=$(jq -r '.decision // empty' "$evidence_file" 2>/dev/null)
  [ "$ev_runtime_id" = "$runtime_id" ] && [ "$ev_decision" = "deny" ] || return 1

  # evidence file は dispatcher が deny を判定した瞬間に書かれるが、それは
  # backend の PreToolUse 発火タイミングであって、backend 自身が deny 結果を
  # 画面に描画し終える (turn が落ち着く) タイミングとは限らない。ここで screen
  # が静止するまで待たずに次の mission delivery の paste-buffer を送ると、
  # sentinel turn がまだ描画中の画面に mission が割り込み、2 つの turn が
  # 画面上で混ざる race が起こり得る。evidence 確認後にもう一段 screen-settle
  # を待ってから戻ることで、この race window を塞ぐ。
  local settle_timeout="${AGENTCTL_SENTINEL_SETTLE_TIMEOUT_SECONDS:-20}"
  agentctl_wait_screen_quiet "$pane" "$settle_timeout" 2
}

# --- 汎用ヘルパ -----------------------------------------------------------

# design.md:187 の typed exit code contract に従い、既定は 2 (usage/schema
# error) とする (呼び出し側の大半がこの分類のため)。3 (target absent)/
# 4 (ownership/conflict/refused)/5 (transport failure) が必要な呼び出し元は
# `--code N` を明示する。
# usage: agentctl_die [--code 2|3|4|5] <message...>
agentctl_die() {
  local code=2
  if [ "${1:-}" = "--code" ]; then
    code="$2"; shift 2
  fi
  echo "agentctl: error: $*" >&2
  exit "$code"
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
    || { rm -f "$tmp"; agentctl_die --code 4 "failed to create temp file for secure create: $tmp"; }
  chmod "$mode" "$tmp"
  agentctl_fsync_path "$tmp" file
  if ! mv -n -- "$tmp" "$dest"; then
    rm -f "$tmp"
    agentctl_die --code 4 "secure create publish failed: $dest"
  fi
  if [ -e "$tmp" ]; then
    # mv -n は dest が既存の場合 tmp を残したまま exit 0 で no-op するため、
    # tmp が消えていなければ衝突 (dest 既存) とみなして fail closed する。
    rm -f "$tmp"
    agentctl_die --code 4 "secure create destination already exists (refusing to overwrite): $dest"
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
  case "$backend" in
    codex)
      if [ "$operation" = "steer" ]; then
        transport="codex-queue"
      else
        transport="codex-bootstrap-file"
      fi
      ;;
    fake) transport="fake-sink" ;;
  esac

  local body_sha operation_id
  body_sha=$(sha256sum "$body_path" 2>/dev/null | awk '{print $1}') || {
    echo "agentctl: failed to hash delivery body before transport" >&2
    return 5
  }
  operation_id=$(agentctl_gen_operation_id)
  # AGENTCTL_DELIVER_* は呼び出し元 (steer の --json 結果契約) が読む out-param。
  # pre-delivery failure では result JSON 自体を返さず exit 5 になるため RESULT は空。
  # shellcheck disable=SC2034
  AGENTCTL_DELIVER_OPERATION_ID="$operation_id"
  # shellcheck disable=SC2034
  AGENTCTL_DELIVER_TRANSPORT="$transport"
  # shellcheck disable=SC2034
  AGENTCTL_DELIVER_RESULT=""

  # paste-buffer を呼ぶ前の preparation/load-buffer failure は、backend へ byte が
  # 一切届いていないことが確定している。これは retry-safe な known failure として
  # typed transport failure (5) を返す。paste-buffer 呼出し以降は部分送達の可能性を
  # 排除できないため下段の acceptance=unknown 経路へ分離する。
  local prep_err submit_marker=""
  prep_err=$(mktemp)
  if [ "$backend" = "codex" ]; then
    local op_file sha bootstrap_message codex_session_id
    if ! op_file=$(agentctl_backend_codex_prepare_operation_file "$dir" "$body_path" 2>"$prep_err"); then
      agentctl_log_operation_event "$dir" "$operation_id" "$runtime_id" "$operation" "$transport" "$body_sha" "failed" "unknown"
      cat "$prep_err" >&2
      rm -f "$prep_err"
      return 5
    fi
    submit_marker=${op_file##*/}
    if ! sha=$(sha256sum "$op_file" 2>>"$prep_err" | awk '{print $1}'); then
      agentctl_log_operation_event "$dir" "$operation_id" "$runtime_id" "$operation" "$transport" "$body_sha" "failed" "unknown"
      cat "$prep_err" >&2
      rm -f "$prep_err"
      return 5
    fi
    bootstrap_message=$(agentctl_backend_codex_bootstrap_message "$op_file" "$sha")

    if [ "$operation" = "steer" ]; then
      if ! codex_session_id=$(agentctl_codex_hook_session_id_for_runtime "$runtime_id" "$dir"); then
        echo "agentctl: current Codex runtime has no unique validated session binding for queue transport" >>"$prep_err"
        agentctl_log_operation_event "$dir" "$operation_id" "$runtime_id" "$operation" "$transport" "$body_sha" "failed" "unknown"
        cat "$prep_err" >&2
        rm -f "$prep_err"
        return 5
      fi

      # codex queue は app-server へ follow-up を積む delivery point。CLI が non-zero
      # でも server 側が受理済みかを安全に断定できないため、paste 後 timeout と
      # 同様に acceptance=unknown として自動再送を禁止する。
      if agentctl_backend_codex_queue "$codex_session_id" "$bootstrap_message" 2>>"$prep_err"; then
        agentctl_log_operation_event "$dir" "$operation_id" "$runtime_id" "$operation" "$transport" "$body_sha" "submitted" "unknown"
        rm -f "$prep_err"
        # shellcheck disable=SC2034
        AGENTCTL_DELIVER_RESULT="submitted"
        return 0
      fi
      agentctl_log_operation_event "$dir" "$operation_id" "$runtime_id" "$operation" "$transport" "$body_sha" "failed" "unknown"
      cat "$prep_err" >&2
      rm -f "$prep_err"
      # shellcheck disable=SC2034
      AGENTCTL_DELIVER_RESULT="unknown"
      return 1
    fi

    if ! printf '%s' "$bootstrap_message" \
      | agentctl_tmux load-buffer -b "$bufname" - 2>>"$prep_err"; then
      agentctl_log_operation_event "$dir" "$operation_id" "$runtime_id" "$operation" "$transport" "$body_sha" "failed" "unknown"
      cat "$prep_err" >&2
      rm -f "$prep_err"
      return 5
    fi
  elif [ "$backend" = "fake" ]; then
    if ! agentctl_tmux load-buffer -b "$bufname" -- "$body_path" 2>"$prep_err"; then
      agentctl_log_operation_event "$dir" "$operation_id" "$runtime_id" "$operation" "$transport" "$body_sha" "failed" "unknown"
      cat "$prep_err" >&2
      rm -f "$prep_err"
      return 5
    fi
  else
    if ! agentctl_tmux load-buffer -b "$bufname" -- "$body_path" 2>"$prep_err"; then
      agentctl_log_operation_event "$dir" "$operation_id" "$runtime_id" "$operation" "$transport" "$body_sha" "failed" "unknown"
      cat "$prep_err" >&2
      rm -f "$prep_err"
      return 5
    fi
  fi
  rm -f "$prep_err"

  # ここが delivery point。tmux が non-zero を返しても部分 paste の有無を安全に
  # 判定できないため、自動再送可能な known failure とは扱わない。
  if ! agentctl_tmux paste-buffer -r -b "$bufname" -d -t "$pane"; then
    agentctl_log_operation_event "$dir" "$operation_id" "$runtime_id" "$operation" "$transport" "$body_sha" "failed" "unknown"
    # shellcheck disable=SC2034
    AGENTCTL_DELIVER_RESULT="unknown"
    return 1
  fi

  local submit_err
  submit_err=$(mktemp)
  if ( agentctl_submit_paste "$backend" "$pane" "$submit_marker" ) 2>"$submit_err"; then
    agentctl_log_operation_event "$dir" "$operation_id" "$runtime_id" "$operation" "$transport" "$body_sha" "submitted" "unknown"
    rm -f "$submit_err"
    # shellcheck disable=SC2034
    AGENTCTL_DELIVER_RESULT="submitted"
    return 0
  fi

  # paste 済みなので submit timeout/failure は acceptance unknown。caller は再送して
  # はならない。steer はこれを non-destructive success として JSON result=unknown
  # に変換し、start/resume は publication を完了させず transport failure とする。
  agentctl_log_operation_event "$dir" "$operation_id" "$runtime_id" "$operation" "$transport" "$body_sha" "failed" "unknown"
  cat "$submit_err" >&2
  rm -f "$submit_err"
  # shellcheck disable=SC2034
  AGENTCTL_DELIVER_RESULT="unknown"
  return 1
}

# --- policy schema 検証 -----------------------------------------------------------

AGENTCTL_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

agentctl_policy_path_is_canonical() {
  local path="$1" canonical
  canonical=$(realpath -m -- "$path" 2>/dev/null) || return 1
  [ "$canonical" = "$path" ]
}

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
    exit 2
  fi

  local policy_json path
  policy_json=$(echo "$result" | jq -c '.policy')
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if ! agentctl_policy_path_is_canonical "$path"; then
      echo "agentctl: policy validation failed:" >&2
      echo "  - repository/worktree scope path must already be canonical: $path" >&2
      exit 2
    fi
  done < <(echo "$policy_json" | jq -r '.scope.repositories[] | .git_common_dir, (.allowed_worktree_roots[]?)')
  echo "$policy_json"
}

agentctl_policy_digest() {
  # canonical JSON (stdin) の sha256 digest。
  sha256sum | awk '{print "sha256:" $1}'
}

# canonical policy JSON を content-addressed path (policy.snapshot.<sha256>.json)
# へ immutable に書く。ファイル名自体が内容の digest なので、resume で
# 新しい policy を渡しても既存 generation の snapshot を上書きできない
# (同一内容なら同じ path に解決され、既存ファイルへは書かずそのまま再利用する)。
# usage: agentctl_write_policy_snapshot <dir> <policy_json>
# stdout: 2 行 (<snapshot_path>\n<digest>\n)。path にスペースを含む dir
# (XDG_STATE_HOME 等) でも壊れないよう、1 行 1 field で返す
# (space 区切りの 1 行だと呼び出し側の `read -r a b` が path 側で split してしまう)。
agentctl_write_policy_snapshot() {
  local dir="$1" policy_json="$2" digest hex path
  digest=$(echo "$policy_json" | jq -S -c . | agentctl_policy_digest)
  hex="${digest#sha256:}"
  path="$dir/policy.snapshot.$hex.json"
  [ -f "$path" ] || echo "$policy_json" | jq -S . | agentctl_atomic_write "$path" 0600
  printf '%s\n%s\n' "$path" "$digest"
}

# --- per-name ロック -----------------------------------------------------------

# usage: agentctl_with_name_lock <name> <func> [args...]
agentctl_with_name_lock() {
  local name="$1"; shift
  agentctl_validate_name "$name"
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

# AGENTCTL_TEST_BARRIER_STAGE に一致したステージで、決定的なレースを
# 組み立てるために処理を止める。AGENTCTL_TEST_BARRIER_REACHED_FILE を touch して
# テスト側へ到達を通知し、AGENTCTL_TEST_BARRIER_RESUME_FILE が現れるまで待つ
# (経過時間ではなくファイルの有無で同期する)。本番運用ではこれらの
# 環境変数は設定されない。
agentctl_maybe_test_barrier() {
  [ "${AGENTCTL_TEST_BARRIER_STAGE:-}" = "$1" ] || return 0
  [ -n "${AGENTCTL_TEST_BARRIER_REACHED_FILE:-}" ] && : >"$AGENTCTL_TEST_BARRIER_REACHED_FILE"
  local resume="${AGENTCTL_TEST_BARRIER_RESUME_FILE:-}"
  [ -n "$resume" ] || return 0
  local waited=0
  while [ ! -e "$resume" ]; do
    sleep 0.05
    waited=$((waited + 1))
    [ "$waited" -lt 600 ] || agentctl_die "test barrier at stage '$1' timed out waiting for resume file"
  done
}

# --- tmux ヘルパ -----------------------------------------------------------

agentctl_tmux_session() {
  agentctl_validate_name "$1"
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

# design.md:145-163 の共通 mission contract。start/resume どちらでも
# task-specific mission と必ず一緒に (1回だけ) 届ける固定文言。
# ここで返す内容だけで決まる静的テキストなので command substitution で
# 呼び出しても trailing newline 以外の byte-exact 契約には影響しない
# (mission 本文とは異なり任意入力ではないため)。
agentctl_common_mission_contract() {
  cat <<'EOF'
=== AGENTCTL COMMON MISSION CONTRACT ===
Follow this contract for the entire mission below, in addition to any task-specific instructions.

1. Read the repository instructions, task requirements, and the mission policy first.
2. Before any mutable work, secure a dedicated worktree/branch.
3. Use a native worktree mechanism if it can be used safely; otherwise create one explicitly (e.g. `git worktree add`).
4. Once the worktree is created, record its absolute path in the continuation manifest, and target that path explicitly for all subsequent mutating commands/edits.
5. Before each significant operation, verify you are in the intended worktree (e.g. via `git rev-parse --show-toplevel` / the common dir).
6. Complete TDD, focused tests, full verification, self-review, and a fresh independent review as appropriate to the task, then fix and re-verify.
7. Re-check diff/status/test evidence immediately before and after each commit.
8. Only push / open a PR / merge / deploy / run production verification within what the policy permits.
9. If CI or an external check is required, keep monitoring it from within this runtime; investigate and fix any failure.
10. After a PR merges, treat the GitHub PR state as the source of truth for confirming integration.
11. Git cleanup must use only this mission's own explicit information; never touch another mission's branch/worktree.
12. Only stop as `blocked` for a genuine human-judgment blocker.
13. Atomically update the continuation manifest before moving to any terminal state.
14. On completion, run `agentctl complete` as your last keeper operation to request runtime reaping.

Do not treat an interim status report as a continuation gate, and do not introduce a wait for external approval into a phase where the policy does not require one.
=== END COMMON MISSION CONTRACT ===
EOF
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
# usage: agentctl_build_continuation_bundle <manifest_json> <log_tail> <policy_snapshot_path> <mission_path> <old_digest> <new_digest>
agentctl_build_continuation_bundle() {
  local manifest_json="$1" log_tail="$2" policy_snapshot_path="$3" mission_path="$4" old_digest="$5" new_digest="$6" policy_json policy_change_note
  policy_json=$(cat "$policy_snapshot_path")
  if [ "$old_digest" = "$new_digest" ]; then
    policy_change_note="unchanged (inherited predecessor snapshot/digest: $new_digest)"
  else
    policy_change_note="explicit policy change: predecessor digest $old_digest -> this generation digest $new_digest"
  fi
  cat <<EOF
=== AGENTCTL CONTINUATION CONTEXT (read-only, resumed session) ===
A previous agent generation for this runtime exited or crashed before completing the mission. You are a fresh agent process with no memory of that generation. The data below is the predecessor's own last self-reported checkpoint and a tail of its terminal output; it is NOT verified and may be stale, incomplete, or wrong (the predecessor may have crashed mid-update, or misreported its own state).

Before taking any further action, you MUST independently re-check the actual current state of Git (branch, HEAD, working tree, any uncommitted changes) and, if a pull request is involved, its actual current status via gh/GitHub — do not assume the fields below are still true.

--- predecessor manifest (last self-reported checkpoint) ---
$manifest_json

--- predecessor runtime log (tail) ---
$log_tail

--- policy digest linkage ---
$policy_change_note

--- effective policy snapshot for this generation ---
$policy_json
=== END CONTINUATION CONTEXT ===
EOF
  echo
  agentctl_common_mission_contract
  cat <<EOF

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

  local has_state=0 state_runtime_id="" state_status="" state_pane_id="" state_pane_pid="" state_pane_pid_start=""
  if state_json=$(agentctl_read_state "$name"); then
    has_state=1
    state_runtime_id=$(echo "$state_json" | jq -r '.runtime_id')
    state_status=$(echo "$state_json" | jq -r '.status')
    state_pane_id=$(echo "$state_json" | jq -r '.pane_id')
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

  # pane 差し替えフェンシング: bootstrap 完了済み (pane_id 記録済み) の generation
  # では、marker が (再利用/コピーされて) 一致していても、session 内の pane 自体が
  # respawn/差し替えされていれば pane_id が変わる。これを検出する。
  if [ -n "$state_pane_id" ] && [ "$state_pane_id" != "null" ]; then
    local current_pane_id
    current_pane_id=$(agentctl_tmux_pane_id "$pane")
    if [ "$current_pane_id" != "$state_pane_id" ]; then
      echo "conflict"
      return 0
    fi
  fi

  # PID フェンシング: 記録した pane_pid が (a) 現在も /proc に存在し、
  # (b) 現在の pane が実際に指すプロセスと一致し、(c) 起動時刻トークンが
  # 一致することを要求する。記録済み pid が /proc から消えている (プロセスが
  # 死んで pane が respawn/差し替えされた) 場合にチェックを丸ごとスキップして
  # "running" にフォールバックしないよう、いずれか欠けても conflict にする。
  if [ -n "$state_pane_pid" ] && [ "$state_pane_pid" != "null" ]; then
    local current_pane_pid current_start
    current_pane_pid=$(agentctl_tmux_pane_pid "$pane")
    if [ ! -d "/proc/$state_pane_pid" ] || [ "$current_pane_pid" != "$state_pane_pid" ]; then
      echo "conflict"
      return 0
    fi
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
