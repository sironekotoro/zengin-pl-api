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
    local diff_text="$1"
    local file_count removed_count added_count old_line new_line

    file_count="$(grep -cE '^diff --git ' <<<"$diff_text" || true)"
    if [[ "$file_count" -ne 1 ]]; then
        echo "expected exactly one changed file, found ${file_count}" >&2
        return 1
    fi

    if ! grep -qE "^diff --git a/${REQUIRED_REF_FILE//./\\.} b/${REQUIRED_REF_FILE//./\\.}\$" <<<"$diff_text"; then
        echo "the changed file is not exactly ${REQUIRED_REF_FILE}" >&2
        return 1
    fi

    # "---"/"+++" ヘッダは2文字目も同じ記号なので除外し、実際の内容行だけを拾う。
    removed_count="$(grep -cE '^-[^-]' <<<"$diff_text" || true)"
    added_count="$(grep -cE '^\+[^+]' <<<"$diff_text" || true)"

    if [[ "$removed_count" -ne 1 || "$added_count" -ne 1 ]]; then
        echo "expected exactly one removed line and one added line, found -${removed_count}/+${added_count}" >&2
        return 1
    fi

    old_line="$(grep -E '^-[^-]' <<<"$diff_text")"
    new_line="$(grep -E '^\+[^+]' <<<"$diff_text")"
    old_line="${old_line#-}"
    new_line="${new_line#+}"

    if ! validate_sha_format "$old_line" || ! validate_sha_format "$new_line"; then
        echo "the diff is not a 40-character lowercase hex SHA replacement" >&2
        return 1
    fi

    printf '%s %s\n' "$old_line" "$new_line"
}

no_blocking_reviews() {
    local reviews_json="$1"
    local blocking
    blocking="$(jq '[.[] | select(.state == "CHANGES_REQUESTED")] | length' <<<"$reviews_json")"
    [[ "$blocking" -eq 0 ]]
}

# --- gh/GitHub APIに依存する処理 ---

find_candidate_pr() {
    gh pr list --repo "$API_REPO" --base "$REQUIRED_BASE" --head "$REQUIRED_HEAD_BRANCH" \
        --state open --json number --jq '.[0].number // empty'
}

pr_snapshot() {
    local pr_number="$1"
    gh pr view "$pr_number" --repo "$API_REPO" --json \
        author,baseRefName,headRefName,headRefOid,isDraft,files,mergeable,reviews
}

current_head_sha() {
    local pr_number="$1"
    gh pr view "$pr_number" --repo "$API_REPO" --json headRefOid --jq .headRefOid
}

pr_diff() {
    local pr_number="$1"
    gh pr diff "$pr_number" --repo "$API_REPO"
}

review_threads_all_resolved() {
    local pr_number="$1"
    local owner name unresolved
    owner="${API_REPO%%/*}"
    name="${API_REPO##*/}"

    unresolved="$(gh api graphql -f query='
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              reviewThreads(first: 100) {
                nodes { isResolved }
              }
            }
          }
        }' -f owner="$owner" -f name="$name" -F number="$pr_number" \
        --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length')"

    [[ "$unresolved" -eq 0 ]]
}

# zengin-pl-apiリポジトリ自身のPR head SHAに対するcheck-runsが、
# 1件以上存在し、かつ全て成功していることを確認する。
# (該当check-runsが無い場合も「未検証」として失敗扱いにする)
api_ci_all_success() {
    local sha="$1"
    local runs count not_success

    runs="$(gh api "repos/${API_REPO}/commits/${sha}/check-runs" --jq '.check_runs')"
    count="$(jq 'length' <<<"$runs")"

    if [[ "$count" -eq 0 ]]; then
        echo "::warning::no check-runs found for ${API_REPO}@${sha}" >&2
        return 1
    fi

    not_success="$(jq '[.[] | select(.status != "completed" or .conclusion != "success")] | length' <<<"$runs")"
    [[ "$not_success" -eq 0 ]]
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

    local snapshot author base head_branch head_sha is_draft files_json reviews_json mergeable
    snapshot="$(pr_snapshot "$pr_number")"
    author="$(jq -r '.author.login' <<<"$snapshot")"
    base="$(jq -r '.baseRefName' <<<"$snapshot")"
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

    echo "All conditions satisfied; merging PR #${pr_number} (head ${head_sha})"
    merge_pr "$pr_number" "$head_sha"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
