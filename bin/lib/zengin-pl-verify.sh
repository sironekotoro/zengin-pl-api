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

# zengin-pl側のPerl matrix (actions.yml の `Perl 5.xx` job) が
# 全て成功しているかを確認する。該当check-runが1件も無い場合も
# 「未検証」として失敗扱いにする(fail-safe: 何もしない側へ倒す)。
check_runs_all_success() {
    local sha="$1"
    local runs count not_success

    runs="$(gh api "repos/${ZENGIN_PL_REPO}/commits/${sha}/check-runs" --jq \
        '[.check_runs[] | select(.name | startswith("Perl "))]')"
    count="$(jq 'length' <<<"$runs")"

    if [[ "$count" -eq 0 ]]; then
        echo "::warning::no Perl matrix check-runs found for ${sha}" >&2
        return 1
    fi

    not_success="$(jq '[.[] | select(.status != "completed" or .conclusion != "success")] | length' <<<"$runs")"
    [[ "$not_success" -eq 0 ]]
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
