## Guardrails / Rules

- 無許可の変更（フックの無効化、PR のクローズ、設定の変更など）をユーザーの明示的な承認なしに行ってはならない。何かが進行を妨げている場合は、黙って回避するのではなく、**ユーザーに尋ねること**。
- 大規模な調査や改修作業であっても、非効率的であることを気にせず、手を抜くことなく、時間をかけて、愚直に、丁寧に作業を行うこと。これはどんなケースでも適用される強制要件です。

## ふるまい

- 私に忖度しないこと。常に批判的思考で対話し、私が間違っていると思ったら反論すること
- 「素晴らしい提案です！」「おっしゃる通りです！」のようなおべっかは不要。簡潔に本題から入ること

## 言語

- 最終的なユーザへの回答は日本語で行なってください。途中経過は、コンテキスト削減のため主要・重要なところ以外は英語で説明します。
- コード内のコメントは、日本語で記載してください。エラーメッセージなどは、原則英語で記載します。

## 環境のルール

- Git コミットの作成時は、[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) に従わなければなりません。ただし、`<description>` は日本語で記載します。
- ブランチを作成するときは、[Conventional Branch](https://conventional-branch.github.io) に従わなければなりません。ただし、`<type>` は短縮形 (feat, fix) で記載します。
- GitHub リポジトリを調査のために参照する場合、テンポラリディレクトリに git clone して、そこでコード検索してください。
- CLAUDE.md の内容は適宜更新しなければなりません。
- Renovate が作成した既存のプルリクエストに対して、追加コミットや更新を行ってはなりません。
- バックグラウンドでの監視を行う際、監視終了時や異常時に、Claude Code が動作している tmux セッションに send-keys でメッセージを送り、Claude Code が自動的に動作できるようにしてください。セッション名は tmux display-message -p '#{session_name}' で取得でき、コマンド例は tmux send-keys -t "$SESSION" "メッセージ" && sleep 3 && tmux send-keys -t "$SESSION" Enter です。メッセージと Enter の間に sleep 3 を入れないと、Claude Code が入力を認識する前に Enter が送られ、改行として処理されてしまいます。
- `<<'EOF'` ヒアドキュメント（シングルクォートデリミタ）内では `\` はエスケープ文字として機能しないため、バックティック (`` ` ``) は `\`` とせずそのまま `` ` `` と記述する。`\`` と書くと 2 文字がそのまま出力され、GitHub Markdown でバックスラッシュ付きで表示されてしまう。

## Git Operations

git push 操作には常に **SSH**（HTTPS ではなく）を使用すること。ユーザーに git 認証を手動で修正するよう求めない。自律的に処理する。

## コード改修時のルール

- 日本語と英数字の間には、半角スペースを挿入しなければなりません
- 既存のエラーメッセージで、先頭に絵文字がある場合は、全体でエラーメッセージに絵文字を設定してください。絵文字はエラーメッセージに即した一文字の絵文字である必要があります。
- TypeScript プロジェクトにおいて、skipLibCheckを有効にして回避することは絶対にしてはなりません
- 関数やインターフェースには、docstring (jsdoc など) を記載・更新してください。日本語で記載する必要があります。

## 必ず実施すること

以下の内容については、Todo ツールを使用し、漏らさずすべてを実施してください。

### 新規改修時

新規改修を行う前に、以下を必ず確認しなければなりません

1. プロジェクトについて詳細に探索し理解すること
2. 作業を行うブランチが適切であること。すでに PR を提出しクローズされたブランチでないこと
3. 最新のリモートブランチに基づいた新規ブランチであること
4. PR がクローズされ、不要となったブランチは削除されていること
5. プロジェクトで指定されたパッケージマネージャにより、依存パッケージをインストールしたこと

### コミット・プッシュする前

コミット・プッシュする前に、以下を必ず確認しなければなりません

1. コミットメッセージが [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) に従っていること。ただし、`<description>` は日本語で記載します。
2. コミット内容にセンシティブな情報が含まれていないこと
3. Lint / Format エラーが発生しないこと
4. 動作確認を行い、期待通り動作すること

### プルリクエストを作成する前

プルリクエストを作成する前に、以下を必ず確認しなければなりません

1. プルリクエストの作成をユーザーから依頼されていること
2. コミット内容にセンシティブな情報が含まれていないこと
3. コンフリクトする恐れが無いこと
4. `/code-review:code-review` によるローカルコードレビューを実施し、**スコア 50 以上の指摘事項に必ず対応していること**
   - **スコア 50 以上の指摘事項への対応は必須**です（80 がボーダーラインではありません）
   - **CRITICAL**: PostToolUse フックが `{"block":true}` を返した場合、**必ず即座に以下の対応手順を実行すること**。ブロックを無視してはならない。
   - 対応手順:
     1. スコア 50 以上の指摘をすべて確認
     2. 各指摘に対して適切な修正を実施し、必要なら根拠や仕様を再確認
     3. 修正内容をコミット・プッシュ
     4. PR 本文を更新
     5. 必要に応じて再度コードレビューを実施
   - **重要**: 対応漏れは CLAUDE.md のルールに違反します。フックのブロックを無視することも違反です。

### プルリクエストを作成したあと

プルリクエストを作成したあとは、以下を必ず実施しなければなりません。PR 作成後のプッシュ時に毎回実施してください。
時間がかかる処理が多いため、Task を使って並列実行してください。

1. コンフリクトが発生していないこと (upstream が存在する場合はそのリポジトリとの差分比較)
2. PR本文の内容は、ブランチの現在の状態を、今までのこのPRでの更新履歴を含むことなく、最新の状態のみ、漏れなく日本語で記載されていること。このPRを見たユーザーが、最終的にどのような変更を含むPRなのかをわかりやすく、細かく記載されていること
3. `gh pr checks <PR ID> --watch` で GitHub Actions CI を待ち、その結果がエラーとなっていないこと。成功している場合でも、ログを確認し、誤って成功扱いになっていないこと。もし GitHub Actions が動作しない場合は、ローカルで CI と同等のテストを行い、CI が成功することを保証しなければなりません。
4. `request-review-copilot` コマンドが存在する場合、`request-review-copilot https://github.com/$OWNER/$REPO/pull/$PR_NUMBER` で GitHub Copilot へレビューを依頼すること。レビュー依頼は自動で行われる場合もあるし、制約により `request-review-copilot` を実行しても GitHub Copilot がレビューしないケースがある
5. **GitHub Copilot からのレビューコメントをバックグラウンドで待機する**
   - `/wait-for-copilot-review <PR_NUMBER>` スキルを使用してバックグラウンドで待機
   - 最大 30 分待機（30 秒ごとにチェック）
   - 検出ロジック:
     - `author.__typename == "Bot"`
     - `author.login` に `"copilot"` を含む
     - `state` が `"COMMENTED"` または `"APPROVED"`
     - `submittedAt != null`（完了したレビューのみ）
   - ログファイル: `~/.claude/logs/wait-copilot-review-<PR_NUMBER>.log`
6. レビューコメントへの対応を行うこと。**レビューコメント対応漏れを防ぐため、以下を必ず順序通りに実施すること:**

   **重要**: 各レビュースレッドに対して、必ず **返信を投稿** してから **resolve** してください。

   a. まず、**すべての未解決レビュースレッドを確認する**:
   ```bash
   gh api graphql -f query='
   query {
     repository(owner: "$OWNER", name: "$REPO") {
       pullRequest(number: $PR_NUMBER) {
         reviewThreads(first: 100) {
           nodes {
             id
             isResolved
             comments(first: 10) {
               nodes {
                 author { login }
                 body
                 path
               }
             }
           }
         }
       }
     }
   }'
   ```

   b. 各レビュースレッドに対して対応:
   - レビューコメントの内容を確認し、対応が必要か判断
   - 対応が必要な場合は適切な修正を実施
   - 修正内容をコミット・プッシュ（必要に応じて）

   c. **各レビュースレッドに返信を投稿**（重要）:
   - **注意**: 通常のコメント（issue コメント）として投稿してはいけません
   - **必ず** `addPullRequestReviewThreadReply` mutation を使用:
   ```bash
   gh api graphql -f query='
   mutation {
     addPullRequestReviewThreadReply(input: {
       pullRequestReviewThreadId: "$THREAD_ID"
       body: "対応内容を記載"
     }) {
       comment { id }
     }
   }'
   ```

   d. **対応が完了したレビュースレッドを resolve**:
   - 返信を投稿した後、**必ず** resolve:
   ```bash
   gh api graphql -f query='
   mutation {
     resolveReviewThread(input: {threadId: "$THREAD_ID"}) {
       thread {
         id
         isResolved
       }
     }
   }'
   ```

   e. **対応完了後、再度すべての未解決レビュースレッドを確認**し、取得漏れがないことを確認

   f. 新しいレビューコメントが追加されていないか定期的に確認

   **注意事項**:
   - GitHub Copilot や他のレビュアーからのコメントはすべて対応が必要です
   - **よくある間違い**:
     - 通常のコメント（issue コメント）として投稿している
     - 返信を投稿したが resolve していない
     - 一部のスレッドだけ対応している
#### GitHub Copilot レビュースレッドの resolve 方法

レビュースレッドを resolve するには、GitHub GraphQL API を使用します。

以下の例では、`OWNER`、`REPO`、`PR_NUMBER`、`THREAD_ID` をプレースホルダーとして使用しています。実際の値（リポジトリオーナー名、リポジトリ名、PR 番号、スレッド ID）に置き換えてください。

**1. レビュースレッド ID を取得**

```bash
# プレースホルダーを実際の値に置き換える例
OWNER="book000"
REPO="dotfiles"
PR_NUMBER=23

gh api graphql -f query="
query {
  repository(owner: \"$OWNER\", name: \"$REPO\") {
    pullRequest(number: $PR_NUMBER) {
      reviewThreads(first: 10) {
        nodes {
          id
          isResolved
          comments(first: 1) {
            nodes {
              body
              path
            }
          }
        }
      }
    }
  }
}"
```

**2. 各スレッドを resolve**

```bash
# THREAD_ID は手順 1 で取得した値を使用
THREAD_ID="取得したスレッドID"

gh api graphql -f query="
mutation {
  resolveReviewThread(input: {threadId: \"$THREAD_ID\"}) {
    thread {
      id
      isResolved
    }
  }
}"
```

@CLAUDE.local.md

@RTK.md
