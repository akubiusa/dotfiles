---
name: rtk
description: Rust Token Killer の分析・履歴・探索・raw proxy コマンドを使うときの参照 skill。
---

# RTK

Codex では Claude の hook によるコマンド自動書換えは使えない。必要な場合だけ明示的に `rtk` を実行する。

```bash
rtk --version
rtk gain
rtk gain --history
rtk discover
rtk proxy <command>
```

- `rtk gain`: token 節約の集計。
- `rtk gain --history`: コマンド別の履歴。
- `rtk discover`: Claude Code 履歴を対象にした分析であり、Codex 履歴を網羅しないことを明記して扱う。
- `rtk proxy`: フィルタを通さず raw command を実行する。安全確認が必要なコマンドを迂回する目的では使わない。

`rtk gain` が失敗する場合は、同名の Rust Type Kit が PATH にある可能性を `which rtk` と `rtk --version` で確認する。
