#!/bin/bash
# shellcheck disable=SC2015
# SC2015: `check && ok || { deny; return; }` は guard-clause として意図通り。
# agentctl 共有 typed-operation classifier。
# Claude/Codex 両 backend の PreToolUse guard から source される。
# 入力は argv (shell 文字列の再パースではなく配列) で受け取り、
# allow | deny | not_privileged | unknown_privileged のいずれかを返す。
#
# privileged operation の canonical identity resolution は fail closed を優先し、
# v1 では以下の direct simple-command form だけを明示的に受理する。
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


agentctl_classify_resolve_trusted_tool_path() {
  local found
  found=$(command -v -- "$1" 2>/dev/null) || return 1
  [[ "$found" == /* ]] || return 1
  realpath -e -- "$found" 2>/dev/null
}

# hook process 起動時の git/gh executable identity を一度だけ固定する。後段では
# command resolution を変える構文を拒否するため、途中の PATH 変更で bare git/gh の
# identity がすり替わらない。
AGENTCTL_CLASSIFY_TRUSTED_GIT_PATH=$(agentctl_classify_resolve_trusted_tool_path git 2>/dev/null || true)
AGENTCTL_CLASSIFY_TRUSTED_GH_PATH=$(agentctl_classify_resolve_trusted_tool_path gh 2>/dev/null || true)


# argv token が実際の Git/GitHub CLI と同一 identity かを解決する。bare git/gh は
# canonical direct form とし、別 path/name は同一 executable または byte-identical copy
# と確認できた場合だけ同一視する。名前だけが git/gh の別 executable は曖昧として拒否する。
# stdout は git / gh / __ambiguous_privileged__。無関係なら出力なしで rc=1。
agentctl_classify_known_tool_identity() {
  local invoked="$1" resolved="" tool trusted_resolved base
  base=$(basename -- "$invoked")

  if [[ "$invoked" == */* ]]; then
    resolved=$(realpath -e -- "$invoked" 2>/dev/null) || {
      case "$base" in git|gh) echo "__ambiguous_privileged__"; return 0 ;; esac
      return 1
    }
  else
    resolved=$(command -v -- "$invoked" 2>/dev/null) || return 1
    [[ "$resolved" == /* ]] || return 1
    resolved=$(realpath -e -- "$resolved" 2>/dev/null) || return 1
  fi

  for tool in git gh; do
    case "$tool" in
      git) trusted_resolved="$AGENTCTL_CLASSIFY_TRUSTED_GIT_PATH" ;;
      gh) trusted_resolved="$AGENTCTL_CLASSIFY_TRUSTED_GH_PATH" ;;
    esac
    [ -n "$trusted_resolved" ] || continue
    if [ "$resolved" = "$trusted_resolved" ]; then
      printf '%s' "$tool"; return 0
    fi
    if [ -f "$resolved" ] && [ -f "$trusted_resolved" ]; then
      if command -v cmp >/dev/null 2>&1; then
        cmp -s -- "$resolved" "$trusted_resolved" && { printf '%s' "$tool"; return 0; }
      elif command -v sha256sum >/dev/null 2>&1; then
        local resolved_sha trusted_sha
        resolved_sha=$(sha256sum -- "$resolved" 2>/dev/null | awk '{print $1}') || return 1
        trusted_sha=$(sha256sum -- "$trusted_resolved" 2>/dev/null | awk '{print $1}') || return 1
        [ "$resolved_sha" = "$trusted_sha" ] && { printf '%s' "$tool"; return 0; }
      else
        # 別 path の executable identity を比較できない場合は、無関係な command として
        # 暗黙 allow せず曖昧な privileged form として扱う。
        echo "__ambiguous_privileged__"; return 0
      fi
    fi
  done

  case "$base" in
    git|gh) echo "__ambiguous_privileged__"; return 0 ;;
  esac
  return 1
}

# --- git 処理 -----------------------------------------------------------

# privileged な git subcommand の分類。permission 名を返す (commit/push/git_cleanup/worktree_add/remote_delete)。
# 非 privileged (status/diff/log/show/fetch/rev-parse 等) は "" を返す。
agentctl_classify_git_subcommand_permission() {
  case "$1" in
    commit) echo "commit" ;;
    push) echo "push" ;;
    worktree) echo "worktree" ;; # add/remove/prune で個別判定
    branch) echo "git_cleanup" ;; # -d/-D のみ privileged (呼び出し元で絞る)
    clean) echo "git_cleanup" ;;
    reset|checkout|restore) echo "git_cleanup" ;;
    status|diff|log|show|fetch|rev-parse) echo "" ;; # 既知 read-only、not_privileged
    *) echo "__unknown__" ;; # 未知 subcommand は alias/外部実行ファイルを解決し得るため fail closed
  esac
}

# 使い方: agentctl_classify_git <policy_json> <env_csv> <had_env_prefix:0|1> <git-subargs...>
agentctl_classify_git() {
  local policy_json="$1" env_csv="$2" had_env_prefix="$3"; shift 3
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
      --git-dir|--work-tree|--namespace|--config-env)
        bad_override=1
        i=$((i + 1))
        ;;
      --git-dir=*|--work-tree=*|--namespace=*|--config-env=*)
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
        # v1 の privileged Git は `git -C <abs> <subcommand> ...` の direct
        # simple-command form だけを許可する。未知 global option は argv の
        # 解釈/identity を変え得るため privileged では deny、read-only でも
        # unknown_privileged に落とす。
        bad_override=1
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
  if [ "$perm" = "__unknown__" ]; then
    # 未知の subcommand は alias/外部 git-foo 実行ファイルを解決し得るため
    # (既知 read-only allowlist に無い限り) fail closed する。
    echo "unknown_privileged"; return 0
  fi
  if [ -z "$perm" ]; then
    [ "$bad_override" -eq 0 ] && [ "$c_count" -le 1 ] && { echo "not_privileged"; return 0; }
    # override/多重 -C を伴う非privileged 分類の command は静的に安全側判定できない。
    echo "unknown_privileged"; return 0
  fi

  # ここから privileged。先頭の env-assignment word / env wrapper は identity
  # を隠蔽し得るため無条件 deny する。read-only/
  # not_privileged な分類 (上の分岐) には適用しない。
  if [ "$had_env_prefix" = "1" ]; then
    echo "deny"; return 0
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

  # multi-repository identity model: 解決した git_common_dir と一致する
  # scope.repositories[] entry を1件だけ探す (見つからなければ identity 不明として deny)。
  local matched_repo repo_id policy_common_dir policy_worktree_roots
  matched_repo=$(echo "$policy_json" | jq -c --arg gcd "$repo_common_dir" \
    '.scope.repositories // [] | map(select(.git_common_dir == $gcd)) | .[0] // empty')
  repo_id=$(echo "$matched_repo" | jq -r '.id // empty')
  policy_common_dir=$(echo "$matched_repo" | jq -r '.git_common_dir // empty')
  policy_worktree_roots=$(echo "$matched_repo" | jq -c '.allowed_worktree_roots // []')

  case "$subcommand" in
    worktree)
      local wt_op="${rest[0]:-}" wt_target="${rest[1]:-}"
      case "$wt_op" in
        add)
          [ -n "$wt_target" ] && agentctl_classify_is_abs_path "$wt_target" || { echo "deny"; return 0; }
          if [ "$repo_common_dir" != "$policy_common_dir" ]; then echo "deny"; return 0; fi
          # destination はまだ存在しない前提なので、既存の親 directory だけを
          # realpath -e で正規化し、basename と結合した「実際に作成される
          # canonical path」で allowlist 判定する (".."/symlink 越しの
          # allowed_worktree_roots 脱出を防ぐ)。
          local wt_parent wt_canonical
          wt_parent=$(realpath -e -- "$(dirname -- "$wt_target")" 2>/dev/null) || { echo "deny"; return 0; }
          wt_canonical="$wt_parent/$(basename -- "$wt_target")"
          if echo "$policy_worktree_roots" | jq -e --arg t "$wt_canonical" 'any(.[]; . as $root | ($t | startswith($root + "/")) or ($t == $root))' >/dev/null 2>&1; then
            echo "allow"; return 0
          fi
          echo "deny"; return 0
          ;;
        remove)
          [ -n "$wt_target" ] && agentctl_classify_is_abs_path "$wt_target" || { echo "deny"; return 0; }
          local gc
          gc=$(echo "$policy_json" | jq -r '.permissions.git_cleanup // false')
          if [ "$repo_common_dir" != "$policy_common_dir" ] || [ "$gc" != "true" ]; then echo "deny"; return 0; fi
          local wt_canonical
          wt_canonical=$(realpath -e -- "$wt_target" 2>/dev/null) || { echo "deny"; return 0; }
          if echo "$policy_worktree_roots" | jq -e --arg t "$wt_canonical" 'any(.[]; . as $root | ($t | startswith($root + "/")) or ($t == $root))' >/dev/null 2>&1; then
            echo "allow"; return 0
          fi
          echo "deny"; return 0
          ;;
        prune)
          local gc
          gc=$(echo "$policy_json" | jq -r '.permissions.git_cleanup // false')
          if [ "$repo_common_dir" = "$policy_common_dir" ] && [ "$gc" = "true" ]; then echo "allow"; else echo "deny"; fi
          return 0
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
          --force|-f|--force-with-lease*|--force-if-includes|+*|--mirror) echo "deny"; return 0 ;; # force-update/削除を伴い得る form は無条件 deny
          --delete|-d|--prune) saw_delete_flag=1 ;; # remote ref を削除し得るため git_cleanup 判定に載せる
          -u|--set-upstream|--dry-run|--porcelain|--atomic|--follow-tags|--tags|--all|-q|--quiet|-v|--verbose) : ;;
          -*) echo "deny"; return 0 ;; # operand を取る option を含め、未分類 option は remote/refspec parsing を曖昧にする
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
      policy_push_url=$(echo "$policy_json" | jq -r --arg name "$remote_name" --arg rid "$repo_id" \
        '.scope.remotes // [] | map(select(.repository_id == $rid and .name == $name)) | .[0].push_url // empty')
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

# --- gh 処理 -----------------------------------------------------------

# gh の既知 read-only (not_privileged) subcommand/second-arg allowlist。
# ここに無い gh <sub> <sub2> の組み合わせは (pr create/merge を除き)
# unknown_privileged とする (fail closed; gh api 等の任意 mutation や
# issue close 等の未分類 mutation を暗黙 allow しない)。
agentctl_classify_gh_is_known_read_only() {
  local sub="$1" sub2="$2"
  case "$sub" in
    repo) case "$sub2" in view|list) return 0 ;; *) return 1 ;; esac ;;
    pr) case "$sub2" in view|list|diff|status|checks) return 0 ;; *) return 1 ;; esac ;;
    issue) case "$sub2" in view|list) return 0 ;; *) return 1 ;; esac ;;
    run) case "$sub2" in view|list) return 0 ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

# 使い方: agentctl_classify_gh <policy_json> <gh-subargs...>
agentctl_classify_gh() {
  local policy_json="$1"; shift
  local args=("$@")

  # -R/--repo (と --hostname) は subcommand の前後どちらにも出現し得る
  # global option なので、まず取り除いた「subcommand 列」を作ってから
  # sub/sub2 を判定する (`gh -R owner/repo pr merge` のような並び替えで
  # sub が "-R" になり判定をすり抜けるのを防ぐ)。
  local repo="" filtered=() i=0 a repo_count=0 hostname_seen=0
  while [ "$i" -lt "${#args[@]}" ]; do
    a="${args[$i]}"
    case "$a" in
      -R|--repo)
        repo_count=$((repo_count + 1))
        repo="${args[$((i + 1))]:-}"
        i=$((i + 2))
        ;;
      --repo=*)
        repo_count=$((repo_count + 1))
        repo="${a#--repo=}"
        i=$((i + 1))
        ;;
      --hostname)
        hostname_seen=1
        i=$((i + 2))
        ;;
      --hostname=*)
        hostname_seen=1
        i=$((i + 1))
        ;;
      *)
        filtered+=("$a")
        i=$((i + 1))
        ;;
    esac
  done

  local sub="${filtered[0]:-}" sub2="${filtered[1]:-}"
  if [ "$sub" = "pr" ] && { [ "$sub2" = "create" ] || [ "$sub2" = "merge" ]; }; then
    : # 下の privileged 経路へ進む
  elif agentctl_classify_gh_is_known_read_only "$sub" "$sub2"; then
    echo "not_privileged"; return 0
  else
    echo "unknown_privileged"; return 0
  fi

  [ "$hostname_seen" -eq 0 ] || { echo "deny"; return 0; }
  [ "$repo_count" -eq 1 ] && [ -n "$repo" ] || { echo "deny"; return 0; }

  local perm_key
  [ "$sub2" = "create" ] && perm_key="create_pr" || perm_key="merge"
  local perm_val
  perm_val=$(echo "$policy_json" | jq -r --arg k "$perm_key" '.permissions[$k] // false')
  [ "$perm_val" = "true" ] || { echo "deny"; return 0; }

  if echo "$policy_json" | jq -e --arg r "$repo" '.scope.repositories // [] | any(.[]; .github_repo == $r)' >/dev/null 2>&1; then
    echo "allow"; return 0
  fi
  echo "deny"; return 0
}

# --- production deploy/verify 処理 -----------------------------------------------------------

# executable path を realpath -e で正規化する。実在しない path (テスト
# fixture 由来の placeholder のような) はそのまま literal 比較にフォール
# バックする (実在しない path は同一 identity を複数名で指せないため
# canonicalize なしでも安全)。
agentctl_classify_canonicalize_path() {
  realpath -e -- "$1" 2>/dev/null || echo "$1"
}

# 使い方: agentctl_classify_production <policy_json> <argv...>
agentctl_classify_production() {
  local policy_json="$1"; shift
  local args=("$@")
  local exec0="${args[0]:-}"
  local exec0_canonical=""
  [ -n "$exec0" ] && exec0_canonical=$(agentctl_classify_canonicalize_path "$exec0")

  # deploy_argv/verify_argv は exact な argv 全体一致だけを allow 対象にする
  # (startswith prefix match だと承認済み argv の後ろに任意の追加引数
  # (--force 等) を足しても allow され続ける)。argv[0] (実行ファイル
  # identity) は realpath -e で正規化して比較し (相対パスの .. や symlink
  # 越しの同一 identity への迂回を防ぐ)、残りの引数は literal 一致を要求
  # する。permission が enable かどうかに関わらず先に exact match を探し、
  # 見つかれば permission に応じて allow/deny を確定する (not_privileged
  # にはしない)。
  local match_key
  for match_key in deploy verify; do
    local perm_key="deploy" arr_key="deploy_argv"
    [ "$match_key" = "verify" ] && { perm_key="production_verify"; arr_key="verify_argv"; }
    local candidates cand
    candidates=$(echo "$policy_json" | jq -c --arg key "$arr_key" \
      '(.scope.production_targets // [])[] | (.[$key] // [])[]' 2>/dev/null)
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      local cand_len
      cand_len=$(echo "$cand" | jq 'length')
      [ "$cand_len" -eq "${#args[@]}" ] || continue
      local cand0 cand0_canonical
      cand0=$(echo "$cand" | jq -r '.[0]')
      cand0_canonical=$(agentctl_classify_canonicalize_path "$cand0")
      [ "$cand0_canonical" = "$exec0_canonical" ] || continue
      local rest_match=1 idx cand_arg
      for ((idx = 1; idx < cand_len; idx++)); do
        cand_arg=$(echo "$cand" | jq -r --argjson i "$idx" '.[$i]')
        [ "$cand_arg" = "${args[$idx]:-}" ] || { rest_match=0; break; }
      done
      [ "$rest_match" -eq 1 ] || continue
      local perm_val
      perm_val=$(echo "$policy_json" | jq -r --arg k "$perm_key" '.permissions[$k] // false')
      [ "$perm_val" = "true" ] && echo "allow" || echo "deny"
      return 0
    done <<<"$candidates"
  done

  # exact match が無くても、argv[0] の canonical identity が policy 上の
  # 既知 production executable (deploy_argv/verify_argv いずれかの先頭要素)
  # と一致するなら (相対パス/symlink 越しの同一 identity への迂回を含む)、
  # 未承認の args/target を伴う既知 privileged executable の呼び出しとみなし
  # deny する。not_privileged (暗黙 allow) への fallback は、真に未登録の
  # executable にのみ許す。
  if [ -n "$exec0" ]; then
    local known_exec0s known known_canonical
    known_exec0s=$(echo "$policy_json" | jq -r \
      '[(.scope.production_targets // [])[] | ((.deploy_argv // []) + (.verify_argv // []))[] | .[0]?] | unique | .[]?')
    while IFS= read -r known; do
      [ -n "$known" ] || continue
      known_canonical=$(agentctl_classify_canonicalize_path "$known")
      if [ "$known_canonical" = "$exec0_canonical" ]; then
        echo "deny"; return 0
      fi
    done <<<"$known_exec0s"
  fi

  echo "not_privileged"
}

# --- top-level dispatch 処理 -----------------------------------------------------------

# 使い方: agentctl_classify_command <policy_json> [--env "K=V,K=V"] -- <argv...>
# 標準出力: allow | deny | not_privileged | unknown_privileged
agentctl_classify_command() {
  local policy_json="$1"; shift
  local env_csv="" force_env_prefix=0
  while true; do
    case "${1:-}" in
      --env) env_csv="$2"; shift 2 ;;
      --force-env-prefix) force_env_prefix=1; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  local argv=("$@")

  # 先頭の POSIX assignment word (`NAME=value`) は shell 上は env prefix であり
  # 実行対象コマンドの identity には含まれない。剥がさず argv[0] として扱うと
  # `FOO=bar git ...`/`GIT_DIR=x git -C ... push`/`X=1 gh pr merge ...` が
  # git/gh 判定に一切乗らず not_privileged (暗黙 allow) にすり抜ける。剥がした
  # assignment は `--env` と同じ env metadata 経路にマージし (eval は使わない)、
  # 既存の GIT_DIR/GIT_WORK_TREE/GIT_CONFIG_* deny 判定に自然に乗せる。
  local prefix_assignments=()
  while [ "${#argv[@]}" -gt 0 ] && [[ "${argv[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; do
    prefix_assignments+=("${argv[0]}")
    argv=("${argv[@]:1}")
  done
  if [ "${#prefix_assignments[@]}" -gt 0 ]; then
    local joined_prefix
    joined_prefix=$(printf '%s,' "${prefix_assignments[@]}")
    env_csv="${joined_prefix}${env_csv}"
  fi

  if [ "${#argv[@]}" -eq 0 ]; then
    if [ "${#prefix_assignments[@]}" -gt 0 ]; then
      echo "unknown_privileged"
    else
      echo "not_privileged"
    fi
    return 0
  fi

  # 実際の assignment の有無に関わらず env wrapper 経由 (had_env_prefix=1) を
  # force-env-prefix で再帰的に伝播する。`env git ...` は assignment 0 件でも
  # direct simple-command form ではないため deny する。
  local had_env_prefix=0
  { [ "${#prefix_assignments[@]}" -gt 0 ] || [ "$force_env_prefix" -eq 1 ]; } && had_env_prefix=1

  # git/gh は basename だけでは同一視しない。別名 copy/symlink は実 executable
  # identity を照合し、単に git/gh という名前の別 executable は fail closed。
  local cmd0_base tool_identity=""
  cmd0_base=$(basename -- "${argv[0]}")
  tool_identity=$(agentctl_classify_known_tool_identity "${argv[0]}" 2>/dev/null) || tool_identity=""

  case "$tool_identity" in
    git) agentctl_classify_git "$policy_json" "$env_csv" "$had_env_prefix" "${argv[@]:1}"; return 0 ;;
    gh)
      # gh mutation の repository host は ambient GH_HOST でも変えられる。明示
      # prefix は従来どおり unresolved、hook process から継承した GH_HOST は
      # canonical github_repo identity を別 host へ向け得るため deny する。
      if [ "$had_env_prefix" -eq 1 ]; then
        echo "unknown_privileged"; return 0
      fi
      if [[ ",$env_csv," == *,GH_HOST=* ]]; then
        echo "deny"; return 0
      fi
      agentctl_classify_gh "$policy_json" "${argv[@]:1}"; return 0 ;;
    __ambiguous_privileged__)
      echo "unknown_privileged"; return 0
      ;;
    "") : ;;
  esac

  # transparent wrapper として扱うのは literal shell builtin の command/exec だけ。
  # 同名 executable は builtin semantics を継承させず、option 付きも lookup/process state
  # を変え得るため `command CMD...` / `exec CMD...` の最小形だけを透過する。
  case "${argv[0]}" in
    command|exec)
      local rest=("${argv[@]:1}")
      if [ "${#rest[@]}" -eq 0 ] || [[ "${rest[0]}" == -* ]]; then
        echo "unknown_privileged"; return 0
      fi
      local fwd=(--env "$env_csv")
      [ "$had_env_prefix" -eq 1 ] && fwd+=(--force-env-prefix)
      agentctl_classify_command "$policy_json" "${fwd[@]}" -- "${rest[@]}"
      return 0
      ;;
    env)
      local rest=("${argv[@]:1}")
      while [ "${#rest[@]}" -gt 0 ] && [[ "${rest[0]}" == -* ]]; do
        rest=("${rest[@]:1}")
      done
      while [ "${#rest[@]}" -gt 0 ] && [[ "${rest[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; do
        rest=("${rest[@]:1}")
      done
      agentctl_classify_command "$policy_json" --env "$env_csv" --force-env-prefix -- "${rest[@]}"
      return 0
      ;;
    sh|bash|zsh|eval|source|.)
      echo "unknown_privileged"; return 0
      ;;
    export|unset|alias|unalias|hash|enable|builtin|declare|typeset|local|readonly|set|shopt|trap|read|mapfile|readarray|let)
      echo "unknown_privileged"; return 0
      ;;
    printf)
      if [ "${argv[1]:-}" = "-v" ]; then
        echo "unknown_privileged"; return 0
      fi
      ;;
  esac

  # wrapper風 basename を持つ別 path/name は shell builtin ではない。shell interpreter、
  # source、env は path 指定でも privileged identity を静的確定できない形として扱う。
  case "$cmd0_base" in
    command|exec|env|sh|bash|zsh|eval|source)
      echo "unknown_privileged"; return 0
      ;;
    *)
      # argv 内に既知または曖昧な git/gh executable を含む generic wrapper は direct
      # simple-command form ではない。timeout/nice/xargs 等で包んだ privileged operation を
      # unrelated/nonprivileged として暗黙 allow しない。
      local wrapped_token wrapped_identity
      for wrapped_token in "${argv[@]:1}"; do
        wrapped_identity=$(agentctl_classify_known_tool_identity "$wrapped_token" 2>/dev/null) || wrapped_identity=""
        case "$wrapped_identity" in
          git|gh|__ambiguous_privileged__) echo "unknown_privileged"; return 0 ;;
        esac
      done
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
# 使い方: agentctl_classify_shell_command_string <policy_json> [--env "K=V,K=V"] <command-string>
# 標準出力: allow | deny | not_privileged | unknown_privileged
agentctl_classify_shell_command_string() {
  local policy_json="$1"; shift
  local env_csv=""
  if [ "${1:-}" = "--env" ]; then
    env_csv="$2"; shift 2
  fi
  local command_string="$1"

  case "$command_string" in
    *$'\n'*|*$'\r'*)
      echo "unknown_privileged"; return 0 ;;
  esac

  # shellcheck disable=SC2016
  case "$command_string" in
    *'$('*|*'`'*|*'<('*|*'>('*)
      echo "unknown_privileged"; return 0 ;;
  esac

  # parameter/pathname/brace/tilde expansion はこの parser が raw command を見た後に
  # shell が実行する。visible token に無い privileged executable/argument を生成できるため、
  # 部分的な shell evaluation はせず expansion 構文を丸ごと拒否する。
  case "$command_string" in
    *'$'*|*'*'*|*'?'*|*'['*|*'{'*|*'}'*|*'~'*)
      echo "unknown_privileged"; return 0 ;;
  esac

  # `read -ra` は quote/escape を解釈しないナイーブな tokenizer であり、
  # `X="a b" gh ...`/`"gh" pr merge ...` のような quote された identity/
  # assignment を誤分割し得る (静的に一意解決できない)。quote 文字/
  # backslash を含む segment は個別に安全側判定せず丸ごと fail closed する。
  # shellcheck disable=SC1003  # case pattern で literal backslash 自体を検出する。
  case "$command_string" in
    *"'"*|*'"'*|*'\'*)
      echo "unknown_privileged"; return 0 ;;
  esac

  # `&` (バックグラウンド実行) や if/while/for 等の control keyword は
  # 意図的に小さいこの parser では正規化できないため、承認済み simple
  # command の背後に privileged operation を隠し得る compound/control
  # syntax として丸ごと fail closed する (`&&` は既存の segment 分割対象
  # なのでここでは除外する)。
  if [[ "$command_string" =~ (^|[^&])\&([^&]|$) ]]; then
    echo "unknown_privileged"; return 0
  fi
  if [[ "$command_string" =~ (^|[[:space:];])(if|then|else|elif|fi|while|until|do|done|for|select|case|esac|function)([[:space:];]|$) ]]; then
    echo "unknown_privileged"; return 0
  fi

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
