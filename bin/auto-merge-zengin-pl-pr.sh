#!/usr/bin/env bash
#
# sync-zengin-pl-ref.sh が作る `chore/update-zengin-pl` PRについて、
# 極めて限定された安全条件を全て満たした場合だけmergeする。
#
# 設計上の要点:
#   - sync workflow内でPR作成直後にmergeしない。API側CI完了後に別workflow
#     (auto-merge-zengin-pl.yml, workflow_run トリガ)からこのscriptを呼ぶ。
#   - PR作成時に一度検証済みでも、branchが書き換えられている可能性を排除
#     するため、ここで全条件を再取得・再検証する(何も信用して使い回さない)。
#   - 条件を1つでも満たさなければmergeしない。「わからないので進める」は
#     行わない(fail-safe)。
#   - 「今は条件を満たさないだけ(CI未完了・レビュー中・raceで中断等)」は
#     正常な安全停止としてexit 0。「このbot専用branchのはずなのに構成が
#     破綻している」(想定外の author/branch/変更ファイル/diff形状)は
#     exit 1でActions上を赤くする。
#
# 関数は t/07_auto_merge_script.t からsourceして個別に呼び出せるよう、
# 純粋なロジックとgit/gh依存処理を分離している。
# zengin-pl側のSHA検証はbin/lib/zengin-pl-verify.shを共用する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/zengin-pl-verify.sh
source "${SCRIPT_DIR}/lib/zengin-pl-verify.sh"

API_REPO="${API_REPO:-sironekotoro/zengin-pl-api}"
REQUIRED_BASE="${REQUIRED_BASE:-main}"
REQUIRED_HEAD_BRANCH="${REQUIRED_HEAD_BRANCH:-chore/update-zengin-pl}"
REQUIRED_AUTHOR="${REQUIRED_AUTHOR:-app/github-actions}"
REQUIRED_REF_FILE="${REQUIRED_REF_FILE:-zengin-pl.ref}"

# --- 純粋なロジック ---

# `gh pr diff` の生テキストが「zengin-pl.ref 1ファイルだけの、
# 40文字hex 1行 -> 別の40文字hex 1行という置換だけ」であることを検証する。
# 満たせば "OLD_SHA NEW_SHA" を1行標準出力へ返す。
parse_pin_diff() {
    local diff_text="$1" old_line new_line
    local -a lines
    mapfile -t lines < <(printf '%s' "$diff_text")
    # A normal one-line text replacement has exactly these seven records.
    # Reject blank additions, context, extra hunks, mode changes and no-newline markers.
    [[ "${#lines[@]}" -eq 7 ]] || return 1
    [[ "${lines[0]}" == "diff --git a/${REQUIRED_REF_FILE} b/${REQUIRED_REF_FILE}" ]] || return 1
    [[ "${lines[1]}" =~ ^index\ [0-9a-f]+\.\.[0-9a-f]+\ 100644$ ]] || return 1
    [[ "${lines[2]}" == "--- a/${REQUIRED_REF_FILE}" ]] || return 1
    [[ "${lines[3]}" == "+++ b/${REQUIRED_REF_FILE}" ]] || return 1
    [[ "${lines[4]}" == '@@ -1 +1 @@' ]] || return 1
    [[ "${lines[5]}" =~ ^-[0-9a-f]{40}$ ]] || return 1
    [[ "${lines[6]}" =~ ^\+[0-9a-f]{40}$ ]] || return 1
    old_line="${lines[5]#-}"
    new_line="${lines[6]#+}"
    [[ "$old_line" != "$new_line" ]] || return 1
    printf '%s %s\n' "$old_line" "$new_line"
}

no_blocking_reviews() {
    local reviews_json="$1"
    jq -e '
        type == "array" and all(.[];
          .state == "APPROVED" or .state == "COMMENTED" or
          .state == "DISMISSED" or .state == "PENDING")
    ' <<<"$reviews_json" >/dev/null
}

# --- gh/GitHub APIに依存する処理 ---

find_candidate_pr() {
    gh pr list --repo "$API_REPO" --base "$REQUIRED_BASE" --head "$REQUIRED_HEAD_BRANCH" \
        --state open --json number --jq '.[0].number // empty'
}

pr_snapshot() {
    local pr_number="$1"
    gh pr view "$pr_number" --repo "$API_REPO" --json \
        author,baseRefName,baseRefOid,headRefName,headRefOid,isCrossRepository,isDraft,files,mergeable,reviews
}

current_head_sha() {
    local pr_number="$1"
    gh pr view "$pr_number" --repo "$API_REPO" --json headRefOid --jq .headRefOid
}

pr_diff() {
    local pr_number="$1"
    gh pr diff "$pr_number" --repo "$API_REPO"
}

# Validate bytes from an immutable commit, not shell command-substitution text
# (which strips trailing newlines). A pin is exactly 40 lowercase hex bytes + LF.
pin_at_sha() {
    local sha="$1" json
    validate_sha_format "$sha" || return 1
    json="$(gh api "repos/${API_REPO}/contents/${REQUIRED_REF_FILE}?ref=${sha}")" || return 1
    jq -e --arg path "$REQUIRED_REF_FILE" '
        .type == "file" and .path == $path and .encoding == "base64" and .size == 41
    ' <<<"$json" >/dev/null || return 1
    jq -er '.content' <<<"$json" | base64 --decode | perl -0777 -e '
        my $bytes = <STDIN> // q{};
        $bytes =~ /\A([0-9a-f]{40})\n\z/ or exit 1; print $1;
    '
}

current_base_sha() {
    gh api "repos/${API_REPO}/commits/${REQUIRED_BASE}" --jq .sha
}

head_contains_base() {
    local base_sha="$1" head_sha="$2" comparison
    comparison="$(gh api "repos/${API_REPO}/compare/${base_sha}...${head_sha}")" || return 1
    jq -e --arg base "$base_sha" '.merge_base_commit.sha == $base' <<<"$comparison" >/dev/null
}

review_threads_all_resolved() {
    local pr_number="$1" pages
    pages="$(gh api graphql --paginate --slurp -f query='
        query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              reviewThreads(first: 100, after: $endCursor) {
                nodes { isResolved }
                pageInfo { hasNextPage endCursor }
              }
            }
          }
        }' -f owner="${API_REPO%%/*}" -f name="${API_REPO##*/}" -F number="$pr_number")" || return 1
    jq -e '
        type == "array" and length > 0 and
        all(.[]; (.errors // [] | length) == 0 and
          (.data.repository.pullRequest.reviewThreads.nodes | type) == "array" and
          all(.data.repository.pullRequest.reviewThreads.nodes[]; .isResolved == true)) and
        (last.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage == false)
    ' <<<"$pages" >/dev/null
}

# Both required jobs must succeed in the latest test.yml run on the exact head.
api_ci_all_success() {
    workflow_ci_success "$API_REPO" test.yml "$REQUIRED_HEAD_BRANCH" "$1" '["test", "docker"]'
}

# `sha`を渡すことで、呼び出し直前に再取得したhead SHAと実際に一致する
# 場合だけGitHub側でmergeを実行させる(TOCTOUを avoid する組み込み機構)。
merge_pr() {
    local pr_number="$1" expected_head_sha="$2"
    gh api --method PUT "repos/${API_REPO}/pulls/${pr_number}/merge" \
        -f "sha=${expected_head_sha}" \
        -f "merge_method=merge"
}

# --- orchestration ---

main() {
    local pr_number
    pr_number="$(find_candidate_pr)"

    if [[ -z "$pr_number" ]]; then
        echo "No open PR from ${REQUIRED_HEAD_BRANCH} to ${REQUIRED_BASE}; nothing to do"
        exit 0
    fi

    echo "Evaluating PR #${pr_number}"

    reject_soft() {
        echo "::notice::not auto-merging PR #${pr_number} (will retry later): $1"
        exit 0
    }
    reject_hard() {
        echo "::error::not auto-merging PR #${pr_number} (unexpected state): $1"
        exit 1
    }

    local snapshot author base base_sha head_branch head_sha is_draft files_json reviews_json mergeable
    snapshot="$(pr_snapshot "$pr_number")"
    author="$(jq -r '.author.login' <<<"$snapshot")"
    base="$(jq -r '.baseRefName' <<<"$snapshot")"
    base_sha="$(jq -r '.baseRefOid' <<<"$snapshot")"
    head_branch="$(jq -r '.headRefName' <<<"$snapshot")"
    head_sha="$(jq -r '.headRefOid' <<<"$snapshot")"
    is_draft="$(jq -r '.isDraft' <<<"$snapshot")"
    files_json="$(jq -c '.files' <<<"$snapshot")"
    reviews_json="$(jq -c '.reviews' <<<"$snapshot")"
    mergeable="$(jq -r '.mergeable' <<<"$snapshot")"

    # 1-5: このPRがそもそも「更新用bot PR」の形をしているか。
    # 崩れていたらbranch/scriptの構成異常として赤くする。
    [[ "$author" == "$REQUIRED_AUTHOR" ]] || reject_hard "unexpected author '${author}' (expected ${REQUIRED_AUTHOR})"
    [[ "$base" == "$REQUIRED_BASE" ]] || reject_hard "unexpected base branch '${base}'"
    [[ "$head_branch" == "$REQUIRED_HEAD_BRANCH" ]] || reject_hard "unexpected head branch '${head_branch}'"
    [[ "$is_draft" == "false" ]] || reject_hard "PR is a draft"
    jq -e '.isCrossRepository == false' <<<"$snapshot" >/dev/null || reject_hard "cross-repository or unknown PR origin"
    validate_sha_format "$head_sha" && validate_sha_format "$base_sha" || reject_hard "invalid head/base SHA"
    local latest_base_sha
    latest_base_sha="$(current_base_sha)" || reject_soft "could not read current base SHA"
    [[ "$latest_base_sha" == "$base_sha" ]] || reject_soft "base branch changed since snapshot"
    head_contains_base "$base_sha" "$head_sha" || reject_soft "PR branch is behind main; refresh branch and approve fresh CI"

    local file_count file_path
    file_count="$(jq 'length' <<<"$files_json")"
    [[ "$file_count" -eq 1 ]] || reject_hard "expected exactly 1 changed file, found ${file_count}"
    file_path="$(jq -r '.[0].path' <<<"$files_json")"
    [[ "$file_path" == "$REQUIRED_REF_FILE" ]] || reject_hard "unexpected changed file '${file_path}'"

    # 8: diffがSHA 1行置換だけであることを確認する。
    local diff_text pin_result old_sha new_sha
    diff_text="$(pr_diff "$pr_number")"
    if ! pin_result="$(parse_pin_diff "$diff_text")"; then
        reject_hard "diff is not a single 40-hex SHA replacement in ${REQUIRED_REF_FILE}"
    fi
    read -r old_sha new_sha <<<"$pin_result"
    local base_pin head_pin
    base_pin="$(pin_at_sha "$base_sha")" || reject_hard "base pin bytes do not match the diff"
    head_pin="$(pin_at_sha "$head_sha")" || reject_hard "head pin bytes do not match the diff"
    [[ "$base_pin" == "$old_sha" ]] || reject_hard "base pin bytes do not match the diff"
    [[ "$head_pin" == "$new_sha" ]] || reject_hard "head pin bytes do not match the diff"
    echo "Candidate pin update: ${old_sha} -> ${new_sha}"

    # 13-14: レビュー状態。「今はまだ」なので正常停止(soft)。
    no_blocking_reviews "$reviews_json" || reject_soft "a review requests changes"
    review_threads_all_resolved "$pr_number" || reject_soft "unresolved review threads remain"

    # 15: merge conflict。branch protectionが無くてもraw mergeabilityは見る。
    [[ "$mergeable" == "MERGEABLE" ]] || reject_soft "PR is not cleanly mergeable (mergeable=${mergeable})"

    # 9-11: zengin-pl側の新SHAを再検証する(PR作成時の検証を信用せず、
    # 実在・master祖先・CI成功をここでもう一度確認する)。
    local clone_dir
    clone_dir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${clone_dir}'" EXIT
    clone_zengin_pl "$clone_dir"
    verify_zengin_pl_sha "$clone_dir" "$new_sha" || reject_hard "new SHA ${new_sha} failed zengin-pl re-verification"

    # 12: zengin-pl-api自身のPR CI(Perl tests, Docker/Schemathesis等)。
    api_ci_all_success "$head_sha" || reject_soft "zengin-pl-api CI is not fully green for ${head_sha}"

    # 16: 検証開始時に読んだhead SHAが今も変わっていないか。
    # 変わっていれば、検証したのは既に古いcommitなのでmergeしない。
    local latest_head_sha
    latest_head_sha="$(current_head_sha "$pr_number")"
    if [[ "$latest_head_sha" != "$head_sha" ]]; then
        reject_soft "PR head changed during validation (${head_sha} -> ${latest_head_sha}); will re-evaluate next run"
    fi

    # GitHub merge API has a head-SHA precondition but no base-SHA precondition.
    # This catches observed base movement, not movement after this final read.
    latest_base_sha="$(current_base_sha)" || reject_soft "could not re-read current base SHA"
    [[ "$latest_base_sha" == "$base_sha" ]] || reject_soft "main changed during validation; refresh branch and approve fresh CI"

    echo "All conditions satisfied; merging PR #${pr_number} (head ${head_sha})"
    local result merged_sha
    result="$(merge_pr "$pr_number" "$head_sha")"
    jq -e '.merged == true' <<<"$result" >/dev/null || reject_hard "merge API did not confirm a merge"
    merged_sha="$(jq -er '.sha' <<<"$result")"
    validate_sha_format "$merged_sha" || reject_hard "merge API returned an invalid SHA"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf 'merged_sha=%s\n' "$merged_sha" >> "$GITHUB_OUTPUT"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

