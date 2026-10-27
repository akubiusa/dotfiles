#!/bin/bash

# 使い方: watch-pr-events.sh <OWNER> <REPO> <PR_NUMBER> <DEADLINE_EPOCH>
# イベントごとに標準出力へ 1 行出す (pr_closed / pr_conflict_detected / ci_failed / ci_all_success /
# review_feedback / monitor_deadline_reached / WARNING)。pr_closed と monitor_deadline_reached の後は 0 で終了し、引数が不正なら 2 で終了する。
set -u

OWNER="${1:-}"
REPO="${2:-}"
PR_NUMBER="${3:-}"
DEADLINE_EPOCH="${4:-}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"

if ! [[ "$OWNER" =~ ^[A-Za-z0-9._-]+$ ]] || ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: OWNER/REPO must match ^[A-Za-z0-9._-]+\$, got: '$OWNER' '$REPO'" >&2
    exit 2
fi
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || ! [[ "$DEADLINE_EPOCH" =~ ^[0-9]+$ ]]; then
    echo "ERROR: PR_NUMBER and DEADLINE_EPOCH must be numeric, got: '$PR_NUMBER' '$DEADLINE_EPOCH'" >&2
    exit 2
fi

PR_URL="https://github.com/${OWNER}/${REPO}/pull/${PR_NUMBER}"
NOTIFY="$HOME/.claude/scripts/completion-notify/send-discord-notification.sh"

# emit <イベント行> <Discord タイトル> <Discord 色>
emit() {
    echo "$1"
    [[ -x "$NOTIFY" ]] || return 0
    jq -n --arg title "$2" --arg desc "$1" --arg url "$PR_URL" --argjson color "$3" \
        '{embeds: [{title: $title, description: $desc, url: $url, color: $color}]}' \
        | "$NOTIFY" >/dev/null 2>&1 || true
}

# shellcheck disable=SC2016 # GraphQL 変数でありシェル展開ではない
REVIEWS_QUERY='query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviews(first: 100) {
        nodes { author { login __typename } state submittedAt }
      }
      reviewThreads(first: 100) {
        nodes {
          isResolved
          comments(first: 100) { nodes { author { login } } }
        }
      }
    }
  }
}'

last_sig=0
last_failed=""
ci_success_sha=""
prev_mergeable=""
last_head=""
fail_count=0
zero_checks=0
errf=$(mktemp)
trap 'rm -f "$errf" "$errf.out"' EXIT

while true; do
    if [[ "$(date +%s)" -ge "$DEADLINE_EPOCH" ]]; then
        emit "monitor_deadline_reached" "PR monitor deadline reached" 15105570
        exit 0
    fi

    cycle_failed=0
    : >"$errf"

    if view=$(gh pr view "$PR_NUMBER" --repo "$OWNER/$REPO" --json state,mergeable,headRefOid,author 2>>"$errf") && [[ -n "$view" ]]; then
        state=$(jq -r '.state' <<<"$view")
        mergeable=$(jq -r '.mergeable' <<<"$view")
        head=$(jq -r '.headRefOid' <<<"$view")
        pr_author=$(jq -r '.author.login' <<<"$view")

        if [[ "$state" != "OPEN" ]]; then
            emit "pr_closed state=$state" "PR $state" 3447003
            exit 0
        fi

        if [[ "$head" != "$last_head" ]]; then
            last_failed=""
            ci_success_sha=""
            zero_checks=0
            last_head="$head"
        fi

        if [[ "$mergeable" == "CONFLICTING" && "$prev_mergeable" != "CONFLICTING" ]]; then
            emit "pr_conflict_detected mergeable=CONFLICTING" "PR conflict detected" 15158332
        fi
        # 一時的な UNKNOWN で CONFLICTING の記録を消さない
        [[ "$mergeable" == "UNKNOWN" ]] || prev_mergeable="$mergeable"
    else
        cycle_failed=1
    fi

    checks_err=$(gh pr checks "$PR_NUMBER" --repo "$OWNER/$REPO" --json name,bucket 2>&1 >"$errf.out") || true
    checks=$(cat "$errf.out" 2>/dev/null)
    if grep -q "no checks reported" <<<"$checks_err"; then
        checks="[]"
    else
        printf '%s\n' "$checks_err" >>"$errf"
    fi
    if jq -e 'type == "array"' <<<"$checks" >/dev/null 2>&1; then
        if [[ $cycle_failed -eq 0 ]]; then
            failed=$(jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel") | .name] | sort | join(",")' <<<"$checks" | tr -d '[:cntrl:]')
            if [[ -n "$failed" ]]; then
                if [[ "$failed" != "$last_failed" ]]; then
                    emit "ci_failed names=$failed" "PR CI failed" 15158332
                fi
            elif jq -e 'all(.bucket == "pass" or .bucket == "skipping")' <<<"$checks" >/dev/null; then
                # チェックが 0 件の PR は連続 2 回空だった場合のみ成功扱いにする (起動直後は未登録の可能性がある)
                if [[ "$(jq length <<<"$checks")" -eq 0 ]]; then
                    zero_checks=$((zero_checks + 1))
                else
                    zero_checks=2
                fi
                if [[ $zero_checks -ge 2 ]]; then
                    if [[ "$ci_success_sha" != "$last_head" ]]; then
                        emit "ci_all_success" "PR CI all checks passed" 3066993
                        ci_success_sha="$last_head"
                    fi
                fi
            else
                zero_checks=0
            fi
            last_failed="$failed"
        fi
    else
        cycle_failed=1
    fi

    if [[ -n "${pr_author:-}" ]] && gql=$(gh api graphql -f owner="$OWNER" -f repo="$REPO" -F number="$PR_NUMBER" -f query="$REVIEWS_QUERY" 2>>"$errf") && [[ -n "$gql" ]]; then
        summary=$(jq -r --arg author "$pr_author" '
            .data.repository.pullRequest as $pr
            | [
                ([$pr.reviews.nodes[] | select(.submittedAt != null and .author.login != $author)] | length)
                + ([$pr.reviewThreads.nodes[].comments.nodes[] | select(.author.login != $author)] | length),
                ([$pr.reviewThreads.nodes[] | select(.isResolved == false)] | length),
                ([$pr.reviews.nodes[] | select(.author.__typename == "Bot"
                    and (.author.login | ascii_downcase | contains("copilot"))
                    and (.state == "COMMENTED" or .state == "APPROVED")
                    and .submittedAt != null)] | length)
              ] | @tsv' <<<"$gql" 2>/dev/null)
        if [[ -n "$summary" ]]; then
            read -r sig unresolved copilot <<<"$summary"
            if [[ "$sig" -gt "$last_sig" ]]; then
                emit "review_feedback unresolved=$unresolved copilot_reviews=$copilot" "PR review feedback" 3447003
                last_sig="$sig"
            fi
        else
            cycle_failed=1
        fi
    else
        cycle_failed=1
    fi

    if [[ $cycle_failed -eq 1 ]]; then
        fail_count=$((fail_count + 1))
        if [[ $((fail_count % 5)) -eq 0 ]]; then
            last_err=$(grep -v '^[[:space:]]*$' "$errf" | tail -1 | tr -d '[:cntrl:]' | cut -c1-200)
            emit "WARNING consecutive_failures=$fail_count last_error=$last_err" "PR monitor warning" 15105570
        fi
    else
        fail_count=0
    fi

    sleep "$POLL_INTERVAL"
done
