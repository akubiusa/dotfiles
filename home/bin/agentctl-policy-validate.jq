# agentctl policy schema validator / canonicalizer.
#
# Input: raw policy JSON (untrusted).
# Output on success: {"ok": true, "policy": <canonical policy object>}
# Output on failure: {"ok": false, "errors": [<string>, ...]}
#
# Fail-closed: any unrecognized shape produces at least one error and "ok": false.
# Never silently defaults an unset permission flag to true.
#
# Canonical shape matches spec (.agent-work/specs/2026-09-10-autonomous-agent-runtime-design.md
# "Mission policy contract"): version:1, permissions.*, scope.repositories[]
# (id/git_common_dir/github_repo/allowed_worktree_roots), scope.remotes[]
# (repository_id/name/push_url), scope.production_targets[] (id/deploy_argv/verify_argv).
# This is a multi-repository identity model: repositories are looked up by id,
# and remotes are scoped to a repository via repository_id (not implicitly global).

def is_abs_path:
  type == "string" and length > 0 and startswith("/");

def is_nonempty_str:
  type == "string" and length > 0;

def is_owner_repo:
  type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$");

def root_errors:
  if (type != "object") then ["policy root must be an object"] else [] end;

def schema_errors:
  if (.version // null) != 1 then
    ["version must be exactly 1 (got: \(.version // null))"]
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

def repositories_errors:
  ((.scope.repositories // null) as $rs
   | if $rs == null or ($rs | type) != "array" or ($rs | length) == 0 then
       ["scope.repositories must be a non-empty array"]
     else
       (($rs | map(select(
           (type != "object")
           or ((.id // null) | is_nonempty_str | not)
           or ((.git_common_dir // null) | is_abs_path | not)
           or ((.github_repo // null) | is_owner_repo | not)
           or (((.allowed_worktree_roots // null) | type) != "array")
         )) | length) as $bad
        | if $bad > 0 then
            ["scope.repositories entries must have id, absolute git_common_dir, OWNER/REPO github_repo, and an allowed_worktree_roots array"]
          else [] end)
       + (($rs | map((.allowed_worktree_roots // []) | map(select(is_abs_path | not))) | flatten | length) as $bad_roots
          | if $bad_roots > 0 then
              ["scope.repositories[].allowed_worktree_roots entries must be absolute paths"]
            else [] end)
       + (($rs | map(.id)) as $ids
          | if ($ids | unique | length) != ($ids | length) then
              ["scope.repositories must not contain duplicate ids"]
            else [] end)
       + (($rs | map(.git_common_dir // empty) | map(select(is_nonempty_str))) as $gcds
          | if ($gcds | unique | length) != ($gcds | length) then
              ["scope.repositories must not contain duplicate git_common_dir"]
            else [] end)
       + (($rs | map(.github_repo // empty) | map(select(is_nonempty_str))) as $grs
          | if ($grs | unique | length) != ($grs | length) then
              ["scope.repositories must not contain duplicate github_repo"]
            else [] end)
     end);

def repository_ids:
  [(.scope.repositories // [])[] | (.id // empty)] | map(select(is_nonempty_str));

def remotes_errors:
  ((.scope.remotes // []) as $rs
   | (repository_ids) as $ids
   | if ($rs | type) != "array" then
       ["scope.remotes must be an array when present"]
     else
       (($rs | map(select(
           (type != "object")
           or ((.repository_id // null) | is_nonempty_str | not)
           or ((.name // null) | is_nonempty_str | not)
           or ((.push_url // null) | is_nonempty_str | not)
         )) | length) as $bad
        | if $bad > 0 then
            ["scope.remotes entries must be objects with non-empty repository_id, name and push_url"]
          else [] end)
       + (($rs | map(.repository_id // empty) | map(select(is_nonempty_str)) | map(select(. as $rid | ($ids | index($rid)) == null)) | length) as $unknown
          | if $unknown > 0 then
              ["scope.remotes entries reference a repository_id not present in scope.repositories"]
            else [] end)
       + (($rs | map(select((.repository_id // null) | is_nonempty_str) | select((.name // null) | is_nonempty_str) | ((.repository_id) + "\u0000" + (.name)))) as $keys
          | if ($keys | unique | length) != ($keys | length) then
              ["scope.remotes must not contain duplicate (repository_id,name) identities"]
            else [] end)
       + (($rs | map(.push_url // empty) | map(select(is_nonempty_str))) as $urls
          | if ($urls | unique | length) != ($urls | length) then
              ["scope.remotes must not contain duplicate push_url"]
            else [] end)
     end);

def is_argv:
  (type == "array") and (length > 0) and (map(is_nonempty_str) | all);

def is_argv_list:
  (type == "array") and (map(is_argv) | all);

def production_targets_errors:
  ((.scope.production_targets // []) as $pts
   | if ($pts | type) != "array" then
       ["scope.production_targets must be an array when present"]
     else
       (($pts | map(select(
           (type != "object")
           or ((.id // null) | is_nonempty_str | not)
           or ((.deploy_argv // []) | is_argv_list | not)
           or ((.verify_argv // []) | is_argv_list | not)
         )) | length) as $bad
        | if $bad > 0 then
            ["scope.production_targets entries must have id, and deploy_argv/verify_argv as arrays of non-empty argv arrays"]
          else [] end)
       + (($pts | map(.id // empty) | map(select(is_nonempty_str))) as $ids
          | if ($ids | unique | length) != ($ids | length) then
              ["scope.production_targets must not contain duplicate ids"]
            else [] end)
     end);

(root_errors
 + schema_errors
 + permissions_errors
 + repositories_errors
 + remotes_errors
 + production_targets_errors) as $errors
| if ($errors | length) > 0 then
    {"ok": false, "errors": $errors}
  else
    {
      "ok": true,
      "policy": {
        "version": 1,
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
        "scope": {
          "repositories": (.scope.repositories | map({
            "id": .id,
            "git_common_dir": .git_common_dir,
            "github_repo": .github_repo,
            "allowed_worktree_roots": (.allowed_worktree_roots | sort)
          })),
          "remotes": (.scope.remotes // []),
          "production_targets": (.scope.production_targets // [])
        }
      }
    }
  end
