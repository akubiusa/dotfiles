# agentctl policy schema validator / canonicalizer.
#
# Input: raw policy JSON (untrusted).
# Output on success: {"ok": true, "policy": <canonical policy object>}
# Output on failure: {"ok": false, "errors": [<string>, ...]}
#
# Fail-closed: any unrecognized shape produces at least one error and "ok": false.
# Never silently defaults an unset permission flag to true.
#
# Canonical shape matches what agentctl-classify.sh reads directly
# (permissions.*, repository.*, remotes[], production_targets[]).

def is_abs_path:
  type == "string" and length > 0 and startswith("/");

def is_nonempty_str:
  type == "string" and length > 0;

def is_owner_repo:
  type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$");

def root_errors:
  if (type != "object") then ["policy root must be an object"] else [] end;

def schema_errors:
  if (.schema_version // null) != 1 then
    ["schema_version must be exactly 1 (got: \(.schema_version // null))"]
  else [] end;

def permission_keys:
  ["local_write", "commit", "push", "create_pr", "merge", "git_cleanup", "deploy", "production_verify"];

def permissions_errors:
  ((.permissions // null) as $p
   | if $p == null or ($p | type) != "object" then
       ["permissions scope is required"]
     else
       # false // null は "//" が false も falsy 扱いするため null に化けるバグ
       # を踏む。has()/直接の型チェックで判定し "// null" は使わない。
       # `$p | has(.)` は pipe が "." を $p に再束縛してしまうため、loop
       # 変数は先に `. as $k` で明示的に束縛してから使う。
       (permission_keys | map(select(. as $k | (($p | has($k)) | not) or ($p[$k] | type != "boolean")))) as $bad
       | if ($bad | length) > 0 then
           ["permissions." + ($bad | join(", permissions.")) + " must be a boolean"]
         else [] end
     end);

def repository_errors:
  ((.repository // null) as $r
   | if $r == null or ($r | type) != "object" then
       ["repository scope is required"]
     else
       (if ($r.git_common_dir // null) == null or ($r.git_common_dir | is_abs_path | not) then
          ["repository.git_common_dir must be a non-empty absolute path"]
        else [] end)
       + (if ($r.github_repo // null) == null or ($r.github_repo | is_owner_repo | not) then
            ["repository.github_repo must match OWNER/REPO"]
          else [] end)
       + (($r.allowed_worktree_roots // null) as $roots
          | if $roots == null or ($roots | type) != "array" then
              ["repository.allowed_worktree_roots must be an array"]
            else
              ($roots | map(select(is_abs_path | not)) | length) as $bad_count
              | (if $bad_count > 0 then
                   ["repository.allowed_worktree_roots entries must be absolute paths"]
                 else [] end)
              + (if ($roots | unique | length) != ($roots | length) then
                   ["repository.allowed_worktree_roots must not contain duplicates"]
                 else [] end)
            end)
     end);

def remotes_errors:
  (.remotes // []) as $rs
  | if ($rs | type) != "array" then
      ["remotes must be an array when present"]
    else
      ($rs | map(select((type != "object")
                         or ((.name // null) | is_nonempty_str | not)
                         or ((.push_url // null) | is_nonempty_str | not))) | length) as $bad
      | (if $bad > 0 then
           ["remotes entries must be objects with non-empty name and push_url"]
         else [] end)
      + (($rs | map(.name)) as $names
         | if ($names | unique | length) != ($names | length) then
             ["remotes must not contain duplicate names"]
           else [] end)
    end;

def is_argv:
  (type == "array") and (length > 0) and (map(is_nonempty_str) | all);

def is_argv_list:
  (type == "array") and (map(is_argv) | all);

def production_targets_errors:
  (.production_targets // []) as $pts
  | if ($pts | type) != "array" then
      ["production_targets must be an array when present"]
    else
      ($pts | map(select(
          (type != "object")
          or ((.deploy_argv // []) | is_argv_list | not)
          or ((.verify_argv // []) | is_argv_list | not)
        )) | length) as $bad
      | if $bad > 0 then
          ["production_targets entries must have deploy_argv/verify_argv as arrays of non-empty argv arrays"]
        else [] end
    end;

def duplicate_identity_errors:
  ([
     (.repository.git_common_dir // empty),
     (.repository.github_repo // empty)
   ] + ((.remotes // []) | map(.push_url // empty))
   | map(select(is_nonempty_str))) as $ids
  | if ($ids | unique | length) != ($ids | length) then
      ["duplicate identity string reused across repository/remotes scope"]
    else [] end;

(root_errors
 + schema_errors
 + permissions_errors
 + repository_errors
 + remotes_errors
 + production_targets_errors
 + duplicate_identity_errors) as $errors
| if ($errors | length) > 0 then
    {"ok": false, "errors": $errors}
  else
    {
      "ok": true,
      "policy": {
        "schema_version": 1,
        "permissions": {
          "local_write": .permissions.local_write,
          "commit": .permissions.commit,
          "push": .permissions.push,
          "create_pr": .permissions.create_pr,
          "merge": .permissions.merge,
          "git_cleanup": .permissions.git_cleanup,
          "deploy": .permissions.deploy,
          "production_verify": .permissions.production_verify
        },
        "repository": {
          "git_common_dir": .repository.git_common_dir,
          "github_repo": .repository.github_repo,
          "allowed_worktree_roots": (.repository.allowed_worktree_roots | sort)
        },
        "remotes": (.remotes // []),
        "production_targets": (.production_targets // [])
      }
    }
  end
