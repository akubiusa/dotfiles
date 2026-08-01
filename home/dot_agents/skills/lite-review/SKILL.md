---
name: lite-review
description: 小規模な GitHub PR またはローカル差分を軽量レビューするときに使う。`$lite-review [PR番号またはURL]`。
---

# Lite Review

`deep-review` と同じ mode 判定、安全基準、採点、報告形式を使う。ただし単一の Codex sub-agent に次の 4 観点をまとめて確認させる: instruction compliance、bugs/correctness、code-comment quality、security。

- 差分、変更要約、適用される `CLAUDE.md` / `AGENTS.md` の全文を渡す。
- 各指摘に観点名、`path:line`、根拠、0–100 の confidence を付け、50 未満を除く。
- PR mode で自分の PR に限り、修正・検証・Conventional Commit・SSH push・PR 本文更新まで実施する。ローカル mode と他者 PR は報告のみ。
- 結果なしの場合は、確認した 4 観点を明記して `No issues found.` と報告する。
