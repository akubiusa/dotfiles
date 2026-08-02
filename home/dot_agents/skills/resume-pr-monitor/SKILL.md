---
name: resume-pr-monitor
description: PR monitor の状態を再観測して、lease を取得した pending event だけを安全に処理するときに使う。`$resume-pr-monitor <PR番号またはURL>`。
---

# PR Monitor Resume

`$resume-pr-monitor <PR 番号または URL>` は action processor の唯一の入口である。watcher と Copilot watcher は event を記録・通知するだけで、cleanup、Git 変更、review handling、GlitchTip 更新を実行しない。

## Reconcile してから処理する

1. `gh pr view` で canonical `PR_URL` を解決する。番号のみでは `gh-pr-target-repo.sh`、次に GitHub の `upstream` remote を優先する。
2. 最初に `~/.agents/skills/pr-health-monitor/scripts/watch-pr.sh once --pr-url "$PR_URL"` を実行する。この command は PR state、checks/conflict、Copilot review を fresh GitHub response から観測し、不足している close、CI failure（run URL を含む）、conflict、Copilot event を state lock 下で enqueue する。API 取得に失敗したら action を実行せず停止する。
3. `pr-monitor-state.sh pending --pr-url "$PR_URL"` を読み、各 action/event について新しいランダム lease ID で `claim --lease-id <ID> --lease-seconds 300` を取得する。claim が exit 3 なら、別の resume が所有しているか event は既に処理済みなので skip する。
4. 長時間 action の前には同じ lease ID で 60 秒ごとに `renew --lease-id <ID> --lease-seconds 300` を実行する heartbeat を開始し、action の終了後に停止する。renew が exit 3 なら ownership を失ったため action を開始・継続せず、結果を報告する。heartbeat は lease を取得した resume だけが実行する。
5. action が成功した場合だけ同じ lease ID で `ack` を実行する。失敗、再検証不一致、またはユーザー判断待ちは同じ lease ID で `release` を実行して pending に戻す。lease のない `ack` は行わない。ack/release 後は heartbeat を停止する。

## Event ごとの action

- `close.cleanup`: fresh PR state が state の terminal value (`MERGED`/`CLOSED`) と一致する場合だけ `$pr-cleanup <PR_URL>` を実行する。
- `copilot_review`: fresh GraphQL query で Copilot review を確認してから `$handle-pr-reviews <PR_URL>` を実行する。
- `ci_failure`: event の `run_url` を使う。空または stale なら `gh pr checks "$PR_URL" --json name,bucket,link` から failed/cancelled check の link を解決し、`gh run view <RUN_ID> --log-failed` で確認する。失敗が継続中なら event は pending のままにする。
- `conflict`: fresh `mergeable`/`mergeStateStatus` が conflict を示す間は event を pending のままにする。rebase、merge、force push は実行しない。

GlitchTip Resolve は durable state callback に保存しないし、自動実行もしない。GlitchTip flow で user が明示的に Resolve を求めた場合だけ、`get_issue(issue_id)`、issue permalink、canonical PR body の正確な `GlitchTip Issue: <permalink URL>`、PR が `MERGED` であることをその時点で再確認して `update_issue(issue_id, status: "resolved")` を実行する。`CLOSED`、metadata 不一致、取得失敗では実行しない。この照合は cryptographic provenance ではないため、任意の state descriptor や argument を callback authority として扱わない。

全 event を reconcile した後も、`watch-pr.sh start` は detached watcher を開始しない。external scheduler がない場合は `foreground_required` を記録して終了する。持続した terminal を user が明示的に用意できる場合だけ、`observed.state` が `OPEN` の PR に `watch-pr.sh watch --pr-url "$PR_URL"` を foreground で実行する。それ以外は resume の再実行を fallback とする。ChatGPT Desktop/Web の Scheduled Tasks を利用できる場合は project context で resume を予定できるが、local shell の detached watcher として扱わない。terminal PR は watcher が final event を enqueue して終了するため、再開しない。restart、agent capacity 不足、tmux 非対応、watcher 停止後もこの手順を使う。
