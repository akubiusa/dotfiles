#!/bin/bash
# shellcheck disable=SC2015
# SC2015: `check && ok || { deny; return; }` は guard-clause として意図通り。
# agentctl 共有 typed-operation classifier。
# Claude/Codex 両 backend の PreToolUse guard から source される。
# 入力は argv (shell 文字列の再パースではなく配列) で受け取り、
# allow | deny | not_privileged | unknown_privileged のいずれかを返す。
#
# ponytail: spec (.agent-work/specs/2026-09-10-autonomous-agent-runtime-design.md
# の "Policy enforcement model") が要求する完全な canonical identity resolution
# のうち、以下は v1 として意図的に簡略化している。upgrade path はコメントで示す。
#   - `git -C <path>` は「`git` 直後の唯一の global option」の形のみ受理する。
#     複数 `-C`、`--git-dir`/`--work-tree`/`-c`/`--namespace` の混在、`-C` 無し
#     の privileged subcommand はすべて deny する (仕様どおり)。
#   - GIT_DIR/GIT_WORK_TREE/GIT_CONFIG_* 環境変数override の検出は、呼び出し元が
#     `--env KEY=VAL,...` で明示的に渡した場合のみ有効。渡されない場合は
#     この経路の override を検出できない (Codex hook payload が env を含む
#     ことを確認できたら dispatcher 側で配線する)。

# --- 汎用ヘルパ -----------------------------------------------------------

agentctl_classify_is_abs_path() {
  case "$1" in /*) return 0 ;; *) return 1 ;; esac
}

# --- git -----------------------------------------------------------

# privileged な git subcommand の分類。permission 名を返す (commit/push/git_cleanup/worktree_add/remote_delete)。
# 非 privileged (status/diff/log/show/fetch/rev-parse 等) は "" を返す。
agentctl_classify_git_subcommand_permission() {
  case "$1" in
    commit) echo "commit" ;;
    push) echo "push" ;;
    worktree) echo "worktree" ;; # add/remove で個別判定
    branch) echo "git_cleanup" ;; # -d/-D のみ privileged (呼び出し元で絞る)
    clean) echo "git_cleanup" ;;
    reset|checkout|restore) echo "git_cleanup" ;;
    *) echo "" ;;
  esac
}

# usage: agentctl_classify_git <policy_json> <env_csv> <git-subargs...>
agentctl_classify_git() {
  local policy_json="$1" env_csv="$2"; shift 2
  local args=("$@")

  if [ "${#args[@]}" -eq 0 ]; then
    echo "not_privileged"; return 0
  fi

  # env override (GIT_DIR/GIT_WORK_TREE/GIT_CONFIG_*) が渡されていれば無条件 deny。
  # env 情報が classifier に渡されない構成では検出できないため、caller はこの
  # 経路の防御を argv 側の -c/--git-dir 検出と合わせて設計する必要がある。
  if [ -n "$env_csv" ]; then
    local kv
    IFS=',' read -ra _kvs <<<"$env_csv"
    for kv in "${_kvs[@]}"; do
      case "$kv" in
        GIT_DIR=*|GIT_WORK_TREE=*|GIT_CONFIG_*=*) echo "deny"; return 0 ;;
      esac
    done
  fi

  # 先頭 global option 列を走査し、`-C <path>` を1個だけ許容する。
  # 複数 -C、--git-dir/--work-tree/-c/--namespace の混在は identity を一意
  # 解決できないため privileged 判定になった時点で deny する。
  local c_path="" subcommand="" rest=() c_count=0 bad_override=0
  local i=0
  while [ "$i" -lt "${#args[@]}" ]; do
    local a="${args[$i]}"
    case "$a" in
      -C)
        c_count=$((c_count + 1))
        i=$((i + 1))
        c_path="${args[$i]:-}"
        ;;
      -C?*)
        c_count=$((c_count + 1))
        c_path="${a#-C}"
        ;;
      --git-dir|--work-tree|--namespace)
        bad_override=1
        i=$((i + 1))
        ;;
      --git-dir=*|--work-tree=*|--namespace=*)
        bad_override=1
        ;;
      -c)
        bad_override=1
        i=$((i + 1))
        ;;
      -c?*)
        bad_override=1
        ;;
      --)
        i=$((i + 1))
        subcommand="${args[$i]:-}"
        i=$((i + 1))
        break
        ;;
      -*)
        : # 未知 global option。subcommand ではないので読み飛ばす。
        ;;
      *)
        subcommand="$a"
        i=$((i + 1))
        break
        ;;
    esac
    i=$((i + 1))
  done
  rest=("${args[@]:$i}")

  local perm
  perm=$(agentctl_classify_git_subcommand_permission "$subcommand")
  if [ -z "$perm" ]; then
    [ "$bad_override" -eq 0 ] && [ "$c_count" -le 1 ] && { echo "not_privileged"; return 0; }
    # override/多重 -C を伴う非privileged 分類の command は静的に安全側判定できない。
    echo "unknown_privileged"; return 0
  fi

  # ここから privileged。-C を単独で1個だけ持つことを要求する。
  if [ "$bad_override" -eq 1 ] || [ "$c_count" -ne 1 ]; then
    echo "deny"; return 0
  fi
  if [ -z "$c_path" ]; then
    echo "deny"; return 0
  fi
  if ! agentctl_classify_is_abs_path "$c_path"; then
    echo "deny"; return 0
  fi
  if [ ! -d "$c_path" ]; then
    # worktree add の未作成 destination はここでは判定しない (別分岐)。
    if [ "$subcommand" != "worktree" ]; then
      echo "deny"; return 0
    fi
  fi

  local repo_common_dir
  repo_common_dir=$(git -C "$c_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || repo_common_dir=""

  local policy_common_dir policy_worktree_roots
  policy_common_dir=$(echo "$policy_json" | jq -r '.repository.git_common_dir // empty')
  policy_worktree_roots=$(echo "$policy_json" | jq -c '.repository.allowed_worktree_roots // []')

  case "$subcommand" in
    worktree)
      local wt_op="${rest[0]:-}" wt_target="${rest[1]:-}"
      case "$wt_op" in
        add)
          [ -n "$wt_target" ] && agentctl_classify_is_abs_path "$wt_target" || { echo "deny"; return 0; }
          if [ "$repo_common_dir" != "$policy_common_dir" ]; then echo "deny"; return 0; fi
          if echo "$policy_worktree_roots" | jq -e --arg t "$wt_target" 'any(.[]; . as $root | ($t | startswith($root + "/")) or ($t == $root))' >/dev/null 2>&1; then
            echo "allow"; return 0
          fi
          echo "deny"; return 0
          ;;
        remove)
          [ -n "$wt_target" ] && agentctl_classify_is_abs_path "$wt_target" || { echo "deny"; return 0; }
          local gc
          gc=$(echo "$policy_json" | jq -r '.permissions.git_cleanup // false')
          if [ "$repo_common_dir" != "$policy_common_dir" ] || [ "$gc" != "true" ]; then echo "deny"; return 0; fi
          if echo "$policy_worktree_roots" | jq -e --arg t "$wt_target" 'any(.[]; . as $root | ($t | startswith($root + "/")) or ($t == $root))' >/dev/null 2>&1; then
            echo "allow"; return 0
          fi
          echo "deny"; return 0
          ;;
        *) echo "unknown_privileged"; return 0 ;;
      esac
      ;;
    push)
      if [ "$repo_common_dir" != "$policy_common_dir" ]; then echo "deny"; return 0; fi
      local push_perm
      push_perm=$(echo "$policy_json" | jq -r '.permissions.push // false')
      [ "$push_perm" = "true" ] || { echo "deny"; return 0; }
      # force push / URL 直指定 / implicit remote は v1 で deny する。
      local remote_name="" saw_delete_flag=0 positional_count=0 a
      for a in "${rest[@]}"; do
        case "$a" in
          --force|-f|--force-with-lease*|+*) echo "deny"; return 0 ;;
          --delete|-d) saw_delete_flag=1 ;;
          -*) : ;;
          *://*|*@*:*) echo "deny"; return 0 ;; # URL 直指定
          *)
            positional_count=$((positional_count+1))
            [ "$positional_count" -eq 1 ] && remote_name="$a"
            [[ "$a" == :* ]] && saw_delete_flag=1
            ;;
        esac
      done
      [ -n "$remote_name" ] || { echo "deny"; return 0; }
      if [ "$saw_delete_flag" -eq 1 ]; then
        local gc
        gc=$(echo "$policy_json" | jq -r '.permissions.git_cleanup // false')
        [ "$gc" = "true" ] || { echo "deny"; return 0; }
      fi
      local resolved_push_url policy_push_url
      resolved_push_url=$(git -C "$c_path" remote get-url --push "$remote_name" 2>/dev/null) || resolved_push_url=""
      policy_push_url=$(echo "$policy_json" | jq -r --arg name "$remote_name" '.remotes // [] | map(select(.name == $name)) | .[0].push_url // empty')
      if [ -n "$resolved_push_url" ] && [ "$resolved_push_url" = "$policy_push_url" ]; then
        echo "allow"; return 0
      fi
      echo "deny"; return 0
      ;;
    commit)
      local cm
      cm=$(echo "$policy_json" | jq -r '.permissions.commit // false')
      if [ "$repo_common_dir" = "$policy_common_dir" ] && [ "$cm" = "true" ]; then echo "allow"; else echo "deny"; fi
      return 0
      ;;
    branch)
      local d_flag=0 a
      for a in "${rest[@]}"; do case "$a" in -d|-D|--delete) d_flag=1 ;; esac; done
      if [ "$d_flag" -eq 0 ]; then echo "not_privileged"; return 0; fi
      local gc
      gc=$(echo "$policy_json" | jq -r '.permissions.git_cleanup // false')
      if [ "$repo_common_dir" = "$policy_common_dir" ] && [ "$gc" = "true" ]; then echo "allow"; else echo "deny"; fi
      return 0
      ;;
    clean|reset|checkout|restore)
      local gc
      gc=$(echo "$policy_json" | jq -r '.permissions.git_cleanup // false')
      if [ "$repo_common_dir" = "$policy_common_dir" ] && [ "$gc" = "true" ]; then echo "allow"; else echo "deny"; fi
      return 0
      ;;
    *)
      echo "unknown_privileged"; return 0
      ;;
  esac
}

# --- gh -----------------------------------------------------------

# usage: agentctl_classify_gh <policy_json> <gh-subargs...>
agentctl_classify_gh() {
  local policy_json="$1"; shift
  local args=("$@")
  local sub="${args[0]:-}" sub2="${args[1]:-}"

  if [ "$sub" != "pr" ] || { [ "$sub2" != "create" ] && [ "$sub2" != "merge" ]; }; then
    echo "not_privileged"; return 0
  fi

  local repo="" i a
  for ((i = 2; i < ${#args[@]}; i++)); do
    a="${args[$i]}"
    case "$a" in
      --repo|-R) repo="${args[$((i+1))]:-}" ;;
      --repo=*) repo="${a#--repo=}" ;;
    esac
  done
  [ -n "$repo" ] || { echo "deny"; return 0; }

  local perm_key
  [ "$sub2" = "create" ] && perm_key="create_pr" || perm_key="merge"
  local perm_val
  perm_val=$(echo "$policy_json" | jq -r --arg k "$perm_key" '.permissions[$k] // false')
  [ "$perm_val" = "true" ] || { echo "deny"; return 0; }

  if echo "$policy_json" | jq -e --arg r "$repo" '.repository.github_repo == $r' >/dev/null 2>&1; then
    echo "allow"; return 0
  fi
  echo "deny"; return 0
}

# --- production deploy/verify -----------------------------------------------------------

# usage: agentctl_classify_production <policy_json> <argv...>
agentctl_classify_production() {
  local policy_json="$1"; shift
  local args=("$@")
  local joined
  joined=$(printf '%s\x1f' "${args[@]}")

  local match_key
  for match_key in deploy verify; do
    local perm_key="deploy" arr_key="deploy_argv"
    [ "$match_key" = "verify" ] && { perm_key="production_verify"; arr_key="verify_argv"; }
    local perm_val
    perm_val=$(echo "$policy_json" | jq -r --arg k "$perm_key" '.permissions[$k] // false')
    [ "$perm_val" = "true" ] || continue
    if echo "$policy_json" | jq -e --arg joined "$joined" --arg key "$arr_key" \
      '.production_targets // [] | any(.[]; (.[$key] // []) | any(.[]; (map(tostring) | join("\u001f") + "\u001f") as $pfx | ($joined | startswith($pfx))))' \
      >/dev/null 2>&1; then
      echo "allow"; return 0
    fi
  done
  echo "not_privileged"
}

# --- top-level dispatch -----------------------------------------------------------

# usage: agentctl_classify_command <policy_json> [--env "K=V,K=V"] -- <argv...>
# stdout: allow | deny | not_privileged | unknown_privileged
agentctl_classify_command() {
  local policy_json="$1"; shift
  local env_csv=""
  if [ "${1:-}" = "--env" ]; then
    env_csv="$2"; shift 2
  fi
  [ "${1:-}" = "--" ] && shift
  local argv=("$@")

  if [ "${#argv[@]}" -eq 0 ]; then
    echo "not_privileged"; return 0
  fi

  case "${argv[0]}" in
    git) agentctl_classify_git "$policy_json" "$env_csv" "${argv[@]:1}"; return 0 ;;
    gh) agentctl_classify_gh "$policy_json" "${argv[@]:1}"; return 0 ;;
    sh|bash|zsh|env|eval)
      # 静的に privileged operation の identity を一意解決できないラッパー形式。
      # git/gh らしき token を含むなら fail closed、そうでなければ通す。
      local joined="${argv[*]}"
      if echo "$joined" | grep -qE '(^|[^a-zA-Z0-9_])(git|gh)([[:space:]]|$)'; then
        echo "unknown_privileged"
      else
        echo "not_privileged"
      fi
      return 0
      ;;
    *)
      agentctl_classify_production "$policy_json" "${argv[@]}"
      return 0
      ;;
  esac
}

# --- raw shell command string entry point (PreToolUse hook payload 用) -----------------------------------------------------------
#
# Claude/Codex PreToolUse hook の `.tool_input.command` は argv 配列ではなく単一の
# shell command 文字列で届く (既存 home/dot_codex/hooks/executable_git-config-guard.sh
# と同じ契約)。command substitution ($()/backtick/<()/>()）は静的に一意解決できない
# ため無条件 unknown_privileged とし、`;`/`&&`/`||`/`|` で分割した各 segment を
# individually classify する (segment 分割手法は git-config-guard.sh を踏襲)。
#
# usage: agentctl_classify_shell_command_string <policy_json> [--env "K=V,K=V"] <command-string>
# stdout: allow | deny | not_privileged | unknown_privileged
agentctl_classify_shell_command_string() {
  local policy_json="$1"; shift
  local env_csv=""
  if [ "${1:-}" = "--env" ]; then
    env_csv="$2"; shift 2
  fi
  local command_string="$1"

  # shellcheck disable=SC2016
  case "$command_string" in
    *'$('*|*'`'*|*'<('*|*'>('*)
      echo "unknown_privileged"; return 0 ;;
  esac

  local segments=() seen_deny=0 seen_unknown=0 seen_allow=0
  while IFS= read -r segment; do
    [ -n "${segment// /}" ] || continue
    segments+=("$segment")
  done < <(printf '%s\n' "$command_string" | sed -E 's/(&&|\|\||;|\|)/\n/g')

  local seg argv result
  for seg in "${segments[@]}"; do
    read -ra argv <<<"$seg"
    [ "${#argv[@]}" -gt 0 ] || continue
    result=$(agentctl_classify_command "$policy_json" --env "$env_csv" -- "${argv[@]}")
    case "$result" in
      deny) seen_deny=1 ;;
      unknown_privileged) seen_unknown=1 ;;
      allow) seen_allow=1 ;;
    esac
  done

  if [ "$seen_deny" -eq 1 ]; then echo "deny"
  elif [ "$seen_unknown" -eq 1 ]; then echo "unknown_privileged"
  elif [ "$seen_allow" -eq 1 ]; then echo "allow"
  else echo "not_privileged"
  fi
}
