#!/usr/bin/env bash
# PROXMOX_* だけを ~/.env から読む (source はしない)。TLS 検証は自己署名証明書のため無効化している。
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: bash pve-api.sh METHOD PATH [curl args...]
  e.g. bash pve-api.sh GET "/cluster/resources?type=vm"
       bash pve-api.sh POST "/nodes/<node>/qemu/<vmid>/agent/ping"
       bash pve-api.sh POST "/nodes/<node>/qemu/<vmid>/monitor" --data-urlencode "command=sendkey alt-grave_accent"
Reads PROXMOX_URL / PROXMOX_USER / PROXMOX_PASSWORD from ~/.env (never sourced).
PROXMOX_URL is https://<host>:8006 (no /api2/json).
The login ticket is cached (mode 0600) in a private 0700 dir under ${XDG_RUNTIME_DIR:-$HOME/.cache}/pve-api, keyed by a hash of PROXMOX_URL + PROXMOX_USER.
TLS verification is disabled (self-signed certificate; trusted LAN only).
USAGE
}

case "${1:-}" in -h | --help)
  usage
  exit 0
  ;;
esac
if [ $# -lt 2 ]; then
  usage
  exit 2
fi

ENV_FILE="${PVE_ENV_FILE:-$HOME/.env}"
if [ ! -r "$ENV_FILE" ]; then
  echo "pve-api: cannot read $ENV_FILE" >&2
  exit 1
fi

# 値は最後に定義された行を採用し、前後が対になった引用符だけを外す。CR は除去する。
# grep の不一致 (終了コード 1) が pipefail + set -e で黙って落ちないよう || true で吸収し、空判定は呼び出し側で行う。
getenv() {
  { grep -E "^(export )?$1=" "$ENV_FILE" || true; } | tail -n 1 | tr -d '\r' |
    sed -E "s/^(export )?$1=//; s/^\"(.*)\"\$/\\1/; t; s/^'(.*)'\$/\\1/"
}

URL=$(getenv PROXMOX_URL)
URL=${URL%/}
USER_NAME=$(getenv PROXMOX_USER)
PASSWORD=$(getenv PROXMOX_PASSWORD)
[ -n "$URL" ] || { echo "pve-api: PROXMOX_URL is missing or empty in $ENV_FILE" >&2; exit 1; }
[ -n "$USER_NAME" ] || { echo "pve-api: PROXMOX_USER is missing or empty in $ENV_FILE" >&2; exit 1; }
[ -n "$PASSWORD" ] || { echo "pve-api: PROXMOX_PASSWORD is missing or empty in $ENV_FILE" >&2; exit 1; }

CACHE_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache}/pve-api"
(umask 077 && mkdir -p "$CACHE_DIR" && chmod 700 "$CACHE_DIR") && [ -O "$CACHE_DIR" ] && [ ! -L "$CACHE_DIR" ] || {
  echo "pve-api: unsafe cache directory $CACHE_DIR" >&2
  exit 1
}
# 接続先とユーザーごとにキャッシュを分ける (~/.env を変えても前のサーバー/ユーザーのチケットを再利用しない)。値自体はファイル名に出さない
CACHE_KEY=$(printf '%s\n%s' "$URL" "$USER_NAME" | sha256sum | cut -c1-16)
CACHE="$CACHE_DIR/ticket-$CACHE_KEY"
MAX_AGE=7000 # PVE のチケット有効期限 (2 時間) より短くする

login() {
  local resp out rc=0
  # パスワードは argv に載せないよう stdin 経由で渡す (printf は組み込みコマンド)
  resp=$(printf '%s' "$PASSWORD" | curl -sk --max-time 15 \
    --data-urlencode "username=$USER_NAME" --data-urlencode "password@-" \
    "$URL/api2/json/access/ticket") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "pve-api: login request failed (curl exit $rc)" >&2
    exit 1
  fi
  out=$(printf '%s' "$resp" | jq -r '.data | select(. != null) | "\(.ticket)\n\(.CSRFPreventionToken)"' 2>/dev/null) || out=""
  if [ -z "$out" ]; then
    echo "pve-api: login rejected or unexpected response (check PROXMOX_* values)" >&2
    exit 1
  fi
  (
    umask 077
    tmp=$(mktemp "$CACHE_DIR/ticket.XXXXXX")
    printf '%s\n' "$out" >"$tmp"
    mv -f "$tmp" "$CACHE"
  )
}

fresh() {
  [ -s "$CACHE" ] && [ $(($(date +%s) - $(stat -c %Y "$CACHE"))) -lt "$MAX_AGE" ]
}

# curl の終了コードをそのまま返す (呼び出し側で転送失敗を検出する)
call() {
  local ticket csrf
  ticket=$(sed -n 1p "$CACHE")
  csrf=$(sed -n 2p "$CACHE")
  curl -sk --max-time 60 -o "$BODY" -w '%{http_code}' -X "$METHOD" \
    -b "PVEAuthCookie=$ticket" -H "CSRFPreventionToken: $csrf" \
    "$URL/api2/json$API_PATH" "$@"
}

request() {
  local rc=0
  code=$(call "$@") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "pve-api: $METHOD $API_PATH request failed (curl exit $rc)" >&2
    exit 1
  fi
}

METHOD=$1
API_PATH=$2
shift 2
BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT
code=
fresh || login
request "$@"
if [ "$code" = 401 ]; then # 期限切れか失効: 一度だけ再ログインする
  login
  request "$@"
fi
cat "$BODY"
[ "$code" -lt 400 ] || {
  echo "pve-api: HTTP $code" >&2
  exit 1
}
