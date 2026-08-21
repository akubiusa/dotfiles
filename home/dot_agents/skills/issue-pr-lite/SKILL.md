---
name: issue-pr-lite
description: 小規模で曖昧さの少ない GitHub Issue を直接実装して PR にするための補助 skill。`$issue-pr-lite <Issue 番号または URL> [<Issue 番号または URL> ...] --owner <owner> --repo <repo>`。`$issue-pr` から委譲される想定で、単独呼び出し時は自分で owner/repo を Issue の URL から抽出する。
---

# Issue to PR: lite path

1. 各 positional argument を順序を保った `ISSUE_REFERENCES` として解析し、`--owner` と `--repo` を除く option や空入力を拒否する。`gh issue view` で Issue、状態、コメント、受入条件を確認する(`--owner`/`--repo` が渡されなければ最初の URL から自分で抽出する)。全 Issue を `gh issue view <reference> --repo "$OWNER/$REPO"` で再取得し、number、canonical URL、state を照合して、すべての Issue が一意、open、target repository 所属であることを検証する。1 件でも重複、closed、別 repository、または scope/acceptance criteria の欠落があれば停止する。Issue ごとに確認済みの scope と acceptance criteria を記録する。Issue ごとの文書として対象範囲と実装方針をコメントに残し、Issue ごとの closing keyword を PR 本文用に記録する。この時点では実装または検証の結果を投稿しない。変更が設計判断を要するほど広がったら停止し、`$issue-pr-deep` への切替を提案する。
2. Conventional Branch を作り、Issue の要求を直接実装する。対象が dotfiles なら `home/` の chezmoi ソースを更新する。
3. PR 作成前の monitor preflight は非変更で、起動能力または選択する fallback だけを確認する。canonical PR URL を取得するまで pane の登録、state/window の作成、watcher の起動をしない。`gh pr create` の前に、PR 作成後に開始できる永続的な terminal または `$resume-pr-monitor <PR URL>` の fallback を選択して維持する。永続的な terminal または resume fallback を選択できない場合は PR を作成せず停止する。
4. 最終ゲートは fail-closed で、HEAD、index、worktree の tracked、staged、untracked と evidence ID を含む snapshot を 1 回記録する。全 substep はこの同じ snapshot を使い、各 substep の直後に比較する。tracked、staged、untracked、evidence のいずれかが変われば、最終ゲート全体を最初からやり直す。
   1. 最新の全検証を実行し、失敗したら停止する。
   2. 直後にシークレット確認を実行し、検出したら停止する。
   3. `$lite-review` のローカル mode を実行する。50 以上、P1、P2 の未解決指摘があれば停止する。
   4. diff、status、evidence を確認する。未記録の検証、未追跡ファイル、意図しない差分があれば停止する。
   5. final evidence 確認後かつ commit/PR 作成直前に同じ snapshot と比較する。commit と PR 作成はこの reviewed snapshot だけを使う。
   6. 差分、status、evidence のいずれかが変われば最終ゲート全体を最初からやり直す。
5. Issue ごとの review evidence を scope/acceptance criteria と対応付け、各 Issue の文書、review evidence、closing keyword が確認済みであることを確認する。すべての Issue の aggregate 最終ゲートが通るまで PR を作成しない。品質ゲートが通った後にのみ、各 Issue に実際に行った実装と検証の結果をコメントとして投稿する。
6. 日本語 Conventional Commit を作成して SSH push する。PR には概要、変更内容、検証を含める。検証済みの各 Issue にだけ `Closes #<issue>` を含める。`--owner`/`--repo` で解決済みの target repository に明示して作成する。
7. PR 作成直後に `$pr-health-monitor <PR 番号または URL>` を実行する。monitor 初期化が失敗した場合の failure report には canonical PR URL、失敗した stage、fresh な evidence、正確な recovery command `$resume-pr-monitor <PR_URL>` を含め、incomplete/unmonitored と報告する。start 成功後の initial CI/review observation の失敗は active な watcher と区別して報告する。XDG state の watcher は close、CI failure、conflict、Copilot review を durable event として記録する。

この skill は仕様/計画の承認ゲートを持たない。曖昧または高リスクな変更に対しては使わない。
