---
name: wait-for-pr-close
description: GitHub PR の close/merge と conflict を durable event として監視するときに使う。`$wait-for-pr-close <PR番号またはURL>`。
---

# PR Close Wait

`$wait-for-pr-close <PR 番号または URL>` は `$pr-health-monitor` の foreground watcher 部分を案内する。watcher は PR state、checks、conflict、Copilot review を poll して XDG state に event を記録するだけで、`$pr-cleanup`、Git 操作、GlitchTip callback は実行しない。

1. `gh pr view` で canonical `PR_URL` を取得する。番号の repository 解決には `gh-pr-target-repo.sh` と GitHub の `upstream` remote を優先する。
2. detached start は使わない。external scheduler がない場合、`start` は `foreground_required` を記録して終了する。持続した terminal を user が明示的に用意できる場合だけ `~/.agents/skills/pr-health-monitor/scripts/watch-pr.sh watch --pr-url "$PR_URL"` を foreground で実行する。それ以外は resume fallback に進む。
3. merge/close、CI failure、conflict、Copilot review は pending event として `${XDG_STATE_HOME:-~/.local/state}/codex-pr-monitor/` に保存される。連続 5 回の API failure で watcher は停止する。
4. terminal state、agent capacity 不足、tmux 非対応、Codex restart、watcher 停止後は `$resume-pr-monitor <PR_URL>` を実行する。ChatGPT Desktop/Web の Scheduled Tasks を利用できる場合は project context で resume を予定できるが、local shell の background 監視ではない。resume はまず fresh GitHub state から event を reconcile し、lease を取得できた action だけを処理する。

GlitchTip callback descriptor は durable state に保存しない。GlitchTip Resolve は user が明示的に要求した verified flow で、`MERGED`、`get_issue`、permalink、PR body を再照合できた場合だけ実行する。`CLOSED` では実行しない。
