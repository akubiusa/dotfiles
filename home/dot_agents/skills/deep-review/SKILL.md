---
name: deep-review
description: GitHub PR またはローカル差分を複数観点で深くレビューするときに使う。`$deep-review [PR番号またはURL]`。
---

# Deep Review

PR 引数ありでは `gh pr view` と `gh pr diff`、引数なしでは merge-base からの差分と作業ツリー差分を対象にする。ローカル差分は報告のみで、コミットや push はしない。

1. PR mode では closed、自動生成 PR、既に自分がレビュー済みの PR を除外する。
2. 変更パスに関係する `CLAUDE.md`、`AGENTS.md`、リポジトリ規約を収集し、差分・変更要約とともにレビュー担当へ渡す。
3. `reviewers/` の固定観点を個別の Codex sub-agent に並列で割り当て、必要なら最大 3 つのプロジェクト固有観点を追加する。docs-only なら compliance と history だけ実行する。
4. 各指摘には変更行の `path:line`、根拠、再現条件を必須とする。未変更行の既存問題、CI が確実に検出する問題、意図的な変更、根拠のない一般論は報告しない。
5. 指摘を 0–100 で再評価し、50 未満を除外する。採点不能なら再評価し、それでも不能な指摘は 50 として明示する。
6. 自分の PR のみ、50 以上の指摘を修正、検証、Conventional Commit、SSH push し、PR 本文を現状に更新する。他者の PR はコメント候補として報告するだけにする。

Codex に Claude の Cron/Agent/Haiku 固定指定はない。利用可能な sub-agent を用い、応答しない担当があれば未確認の観点として最終報告に残す。
