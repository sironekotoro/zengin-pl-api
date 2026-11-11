#!/usr/bin/env bash
#
# zengin-pl (https://github.com/sironekotoro/zengin-pl) 側のcommitを
# 検証するための共通関数。sync-zengin-pl-ref.sh (PR作成) と
# auto-merge-zengin-pl-pr.sh (PR自動merge判定) の両方から source される。
#
# ここでの「検証」は常にfail-safe: 判定に必要な情報が取得できない場合は
# 「検証できなかった」として失敗(非0)を返す。「わからないので成功とみなす」
# は行わない。
#
# このファイル単体では何も実行しない(関数定義のみ)。

ZENGIN_PL_REPO="${ZENGIN_PL_REPO:-sironekotoro/zengin-pl}"
ZENGIN_PL_SHA_RE='^[0-9a-f]{40}$'

validate_sha_format() {
    local sha="$1"
    [[ "$sha" =~ $ZENGIN_PL_SHA_RE ]]
}

# Preserve exact bytes: command substitution would otherwise hide extra LFs.
read_pin_file() {
    perl -0777 -e '
        my $bytes = <> // q{};
        $bytes =~ /\A([0-9a-f]{40})\n\z/ or do {
            warn qq{pin must be exactly 40 lowercase hex characters followed by one LF (41 bytes); got } . length($bytes) . qq{ bytes\n};
            exit 1;
        };
        print $1;
    ' -- "$1"
}

short_sha() {
    local sha="$1"
    printf '%s' "${sha:0:12}"
}

clone_zengin_pl() {
    local dest="$1"
    git clone --quiet "https://github.com/${ZENGIN_PL_REPO}.git" "$dest"
}

fetch_master_head_sha() {
    gh api "repos/${ZENGIN_PL_REPO}/commits/master" --jq .sha
}

# $1: zengin-plをcloneしたローカルpathで、origin/masterがfetch済みであること
# $2: 検証したいSHA
commit_exists() {
    local clone_dir="$1" sha="$2"
    git -C "$clone_dir" cat-file -e "${sha}^{commit}" 2>/dev/null
}

is_ancestor_of_master() {
    local clone_dir="$1" sha="$2"
    git -C "$clone_dir" merge-base --is-ancestor "$sha" origin/master
}

# Read every page; select the newest run for this exact workflow, branch and SHA.
# Never combine jobs from different runs or accept a partial matrix.
workflow_ci_success() {
    local repo="$1" workflow="$2" branch="$3" sha="$4" required="$5"
    local pages run run_id attempt jobs refreshed
    pages="$(gh api --paginate --slurp "repos/${repo}/actions/workflows/${workflow}/runs?head_sha=${sha}&per_page=100")" || return 1
    run="$(jq -ce --arg sha "$sha" --arg branch "$branch" '
        [.[].workflow_runs[] | select(.head_sha == $sha and .head_branch == $branch)
          | select(.event == "pull_request" or .event == "workflow_dispatch" or .event == "push")]
        | sort_by(.id) | last // empty' <<<"$pages")" || return 1
    jq -e '.status == "completed" and .conclusion == "success"' <<<"$run" >/dev/null || return 1
    run_id="$(jq -er '.id | numbers' <<<"$run")" || return 1
    attempt="$(jq -er '.run_attempt | numbers | select(. > 0)' <<<"$run")" || return 1
    jobs="$(gh api --paginate --slurp "repos/${repo}/actions/runs/${run_id}/attempts/${attempt}/jobs?per_page=100")" || return 1
    jq -e --argjson required "$required" '
        [.[].jobs[]] as $jobs |
        all($required[]; . as $name |
          [$jobs[] | select(.name == $name)] as $matches |
          ($matches | length) == 1 and
          all($matches[]; .status == "completed" and .conclusion == "success"))
        and all($jobs[]; .status == "completed" and .conclusion == "success")
    ' <<<"$jobs" >/dev/null || return 1
    # A rerun/new run may have started while jobs were being fetched.
    refreshed="$(gh api --paginate --slurp "repos/${repo}/actions/workflows/${workflow}/runs?head_sha=${sha}&per_page=100")" || return 1
    jq -e --arg sha "$sha" --arg branch "$branch" --argjson id "$run_id" --argjson attempt "$attempt" '
        [.[].workflow_runs[] | select(.head_sha == $sha and .head_branch == $branch)
          | select(.event == "pull_request" or .event == "workflow_dispatch" or .event == "push")]
        | sort_by(.id) | last |
        .id == $id and .run_attempt == $attempt and .status == "completed" and .conclusion == "success"
    ' <<<"$refreshed" >/dev/null
}

check_runs_all_success() {
    workflow_ci_success "$ZENGIN_PL_REPO" actions.yml master "$1" \
        '["Perl 5.36", "Perl 5.38", "Perl 5.40", "Perl 5.42"]'
}

# check-runsの中から代表となる1件のURLを「検証元」として報告用に返す。
representative_check_run_url() {
    local sha="$1"
    gh api "repos/${ZENGIN_PL_REPO}/commits/${sha}/check-runs" --jq \
        '[.check_runs[] | select(.name | startswith("Perl "))][0].html_url // empty'
}

# 1コマンドとして: SHA形式・実在・master祖先・CI成功をまとめて検証する。
# 途中で失敗した場合はstderrに理由を出して非0で返す。
verify_zengin_pl_sha() {
    local clone_dir="$1" sha="$2"

    if ! validate_sha_format "$sha"; then
        echo "::error::'${sha}' is not a 40-character lowercase hex commit SHA" >&2
        return 1
    fi

    if ! commit_exists "$clone_dir" "$sha"; then
        echo "::error::commit ${sha} does not exist in ${ZENGIN_PL_REPO}" >&2
        return 1
    fi

    if ! is_ancestor_of_master "$clone_dir" "$sha"; then
        echo "::error::commit ${sha} is not on ${ZENGIN_PL_REPO}'s master history" >&2
        return 1
    fi

    if ! check_runs_all_success "$sha"; then
        echo "::error::${sha} does not have a fully successful Perl test matrix" >&2
        return 1
    fi

    return 0
}

