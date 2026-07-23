---
name: check-container-status
description: Enumerates Docker Compose projects under a target directory (default current directory), comprehensively checks each one's status (running state, resource usage, restart count, logs, connectivity) via parallel sub-agents (max 5 concurrent), and reports errors with researched fixes once all directories are done. Use on a machine hosting many Docker Compose projects, e.g. /mnt/hdd/<machine-name>.
argument-hint: "[target directory]"
disable-model-invocation: true
---

# Check Container Status

`/mnt/hdd/<マシン名>` のような、多数の Docker Compose プロジェクトが同居する
ディレクトリの稼働状況を、並列サブエージェントで網羅的に確認する。

## 使用法

```
/check-container-status [対象ディレクトリ]
```

引数を省略した場合はカレントディレクトリを対象とする。

## Phase A: 対象ディレクトリの列挙

```bash
TARGET_DIR="${1:-$(pwd)}"
mapfile -t COMPOSE_DIRS < <(bash ~/.claude/skills/check-container-status/scripts/list-compose-dirs.sh "$TARGET_DIR")
```

`COMPOSE_DIRS` が空の場合、Compose プロジェクトが1件も見つからなかった旨を
報告して終了する。

## Phase B: STATE.md の初期化・再開判定

`STATE_FILE="$TARGET_DIR/STATE.md"` とする。

- `STATE_FILE` が存在し、`## Queue` に `pending` または `in_progress` の
  エントリが残っている場合は再開モードとする。`in_progress` のエントリは
  すべて `pending` に戻してから処理を再開する(前回セッションが途中で
  終了した可能性があるため、安全側に倒す)。
- `STATE_FILE` が存在しない、または全件 `done` の場合は新規実行として
  以下のフォーマットで作り直す。

```markdown
# Docker Container Status Check - STATE

## Run Info
- started_at: <ISO8601>
- target_dir: <TARGET_DIR>
- cron_job_id: (Phase C で追記)

## Queue
- pending: <COMPOSE_DIRS を1行1件で列挙>
- in_progress:
- done:

## Results
```

## Phase C: オーケストレーション・ループ

1. `CronCreate` で15分間隔のチェックインジョブを登録する。

   ```
   CronCreate({
     cron: "*/15 * * * *",
     recurring: true,
     prompt: "check-container-status のチェックイン: <STATE_FILE> を確認し、
       in_progress のうち started_at から30分以上経過し応答がないディレクトリを
       pending に戻して再起動し、pending が残っていれば空いている並列枠に
       次のディレクトリを起動してください。全件 done なら Phase D に進んで
       ください。"
   })
   ```

   返された job ID を `STATE_FILE` の `cron_job_id` に記録する。
   `CronCreate` は本セッション内でのみ有効で、セッション終了時に消滅する
   (7日で自動失効もする)。セッションが終了した場合、ユーザーが再度
   `/check-container-status` を呼び出すことで `STATE_FILE` から再開できる。

2. `pending` から最大5件まで(既に `in_progress` の件数を差し引いた分だけ)
   選び、それぞれについて `Agent` ツールを `run_in_background: true` で
   起動する。

   ```
   Agent({
     subagent_type: "container-status-checker",
     description: "Check <dir>",
     prompt: "TARGET_DIR=<dir> STATE_FILE=<STATE_FILE> PREVIOUS_CHECKED_AT=<前回の checked_at があれば>",
     run_in_background: true,
   })
   ```

   起動したら `STATE_FILE` の `pending` からそのディレクトリを取り除き、
   `in_progress` に `<dir> (agent_id: <id>, started_at: <ISO8601>)` の形で追加する。

3. サブエージェントが完了通知を返すたびに、`STATE_FILE` の `in_progress` から
   該当ディレクトリを取り除いて `done` に追加し、`pending` が残っていれば
   次の1件を Step 2 と同じ要領で起動する(常に並列数5を維持する)。

4. 15分ごとの Cron チェックインが発火したら、`in_progress` のうち
   `started_at` から30分以上経過し応答がないエントリを `pending` に戻し、
   Step 2 の要領で再起動する。

5. `pending` と `in_progress` がともに空になったら(全件 `done`)ループを
   終了し、`CronDelete({ id: <cron_job_id> })` でチェックインジョブを削除する。

## Phase D: エラー調査(完了後・一括)

`STATE_FILE` の `## Results` を確認し、`status: error` または
`status: warning` のエントリすべてについて、`container-error-investigator`
サブエージェントを起動する。

```
Agent({
  subagent_type: "container-error-investigator",
  description: "Investigate <dir>",
  prompt: "TARGET_DIR=<dir> STATE_FILE=<STATE_FILE>",
})
```

`ok`/`expected_down` のエントリは調査対象に含めない。

## Phase E: 最終報告

チャット出力として、以下を提示する。

- 全体サマリ(対象ディレクトリ数、`ok`/`expected_down`/`warning`/`error` の内訳)
- ディレクトリ別の状態一覧(`summary` を1行ずつ)
- `warning`/`error` について、Phase D で得られた `diagnosis`(原因・解決策・確信度)

報告後、`STATE_FILE` を `STATE.md.<実行日時>.done` にリネームする。

```bash
mv "$STATE_FILE" "$STATE_FILE.$(date +%Y%m%d%H%M%S).done"
```

同じディレクトリに複数の `.done` ファイルが既に存在する場合は、最新のもの
以外を削除し、直近1世代のみを残す。

## Notes

- 破壊的コマンド(`docker compose restart`/`down`/`up` 等)は本スキル・
  サブエージェントのいずれからも実行しない。read-only な確認と提案に徹する。
- `/mnt/hdd/work/*` のような一時ディレクトリは自動では対象に含まれない。
  必要な場合はそのディレクトリを対象ディレクトリ引数として明示的に指定する。
- 親セッション(このスキルを実行しているセッション)はオーケストレーターに
  徹し、`docker compose` の実行・ログ解析・疎通確認・インターネット調査は
  すべてサブエージェントに委譲する。
