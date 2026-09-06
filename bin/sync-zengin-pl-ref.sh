#!/usr/bin/env bash
#
# zengin-pl master が新しいverified commitへ進んだら、zengin-pl.ref を
# そのSHAへ更新し、専用branchへ更新PRを作成する(既存のPRがあれば更新する)。
#
# 設計上の要点:
#   - zengin-pl側からの書き込み・通知は一切使わない。このscriptは
#     zengin-pl-api自身のGitHub Actions runからzengin-plの公開commit/
#     check-run情報をGitHub APIで読むだけの「pull型」。
#   - zengin-pl.ref以外のファイルは変更しない。
#   - merge・auto-mergeは行わない。PR作成までが責務。
#
# 関数はunit test(t/06_sync_script.t)からsourceして個別に呼び出せるよう、
# ネットワーク/gitに依存する処理と純粋なロジックを分離している。
set -euo pipefail

ZENGIN_PL_REPO="${ZENGIN_PL_REPO:-sironekotoro/zengin-pl}"
ZENGIN_PL_REF_FILE="${ZENGIN_PL_REF_FILE:-zengin-pl.ref}"
SYNC_BRANCH="${SYNC_BRANCH:-chore/update-zengin-pl}"
SHA_RE='^[0-9a-f]{40}$'

# --- 純粋なロジック(network/git不要、または引数で渡されたrepoに対してのみ動作) ---

validate_sha_format() {
    local sha="$1"
    [[ "$sha" =~ $SHA_RE ]]
}

short_sha() {
    local sha="$1"
    printf '%s' "${sha:0:12}"
}

current_pinned_sha() {
    local ref_file="$1"
    if [[ -f "$ref_file" ]]; then
        tr -d '\r\n' < "$ref_file"
    fi
}

# zengin-pl.ref を新SHAへ書き換える。変更があれば0、
# 既に同じ内容なら書き換えずに1を返す(no-op検出)。
write_ref_if_changed() {
    local ref_file="$1" new_sha="$2"
    local current
    current="$(current_pinned_sha "$ref_file")"

    if [[ "$current" == "$new_sha" ]]; then
        return 1
    fi

    printf '%s\n' "$new_sha" > "$ref_file"
    return 0
}

branch_name() {
    printf '%s' "$SYNC_BRANCH"
}

commit_message() {
    local sha="$1"
    printf 'chore: update zengin-pl pin to %s\n' "$(short_sha "$sha")"
}

pr_title() {
    local sha="$1"
    printf 'Update zengin-pl to %s' "$(short_sha "$sha")"
}

pr_body() {
    local old_sha="$1" new_sha="$2" source_url="$3"
    cat <<EOF
これは自動生成PRです([sync-zengin-pl.yml](.github/workflows/sync-zengin-pl.yml)によるcross-repo同期)。

- old SHA: \`${old_sha:-なし}\`
- new SHA: \`${new_sha}\`
- zengin-pl commit: https://github.com/${ZENGIN_PL_REPO}/commit/${new_sha}
- 検証元 workflow run: ${source_url}

zengin-pl側のmaster branch上で存在が確認され、Perl test matrixが
成功したcommitのみをpinしています。このPRの内容は \`${ZENGIN_PL_REF_FILE}\`
の1行だけです。

mergeすると、既存の deploy workflow (\`.github/workflows/deploy.yml\`) が
通常どおり実行され、Cloud Runへ自動deployされます。**このPRは自動merge
されません。** 内容(特にzengin-pl側の変更が本APIにとって意味的に問題
ないか)を人間が確認してからmergeしてください。
EOF
}

# --- git/gh に依存する処理 ---

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

clone_zengin_pl() {
    local dest="$1"
    git clone --quiet "https://github.com/${ZENGIN_PL_REPO}.git" "$dest"
}

fetch_master_head_sha() {
    gh api "repos/${ZENGIN_PL_REPO}/commits/master" --jq .sha
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

ensure_update_pr() {
    local branch="$1" title="$2" body_file="$3"
    local existing

    existing="$(gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty')"

    if [[ -n "$existing" ]]; then
        echo "Updating existing PR #${existing}"
        gh pr edit "$existing" --title "$title" --body-file "$body_file"
    else
        echo "Creating new PR"
        gh pr create --title "$title" --body-file "$body_file" --head "$branch" --base main
    fi
}

# --- orchestration ---

main() {
    local requested_sha="${1:-}"
    local target_sha

    if [[ -n "$requested_sha" ]]; then
        target_sha="$requested_sha"
    else
        echo "No SHA given; resolving zengin-pl master HEAD"
        target_sha="$(fetch_master_head_sha)"
    fi

    if ! validate_sha_format "$target_sha"; then
        echo "::error::'${target_sha}' is not a 40-character lowercase hex commit SHA" >&2
        exit 1
    fi

    local current_sha
    current_sha="$(current_pinned_sha "$ZENGIN_PL_REF_FILE")"

    if [[ "$current_sha" == "$target_sha" ]]; then
        echo "zengin-pl.ref already pins ${target_sha}; nothing to do"
        exit 0
    fi

    local clone_dir
    clone_dir="$(mktemp -d)"
    # clone_dirはmain()のlocal変数なので、関数returnより後に発火するEXIT
    # trapの中で参照すると(その時点では変数が既にscope外)`unbound
    # variable`になる。trap登録時点で値を文字列として埋め込むことで回避する
    # (ここでの即時展開は意図的。shellcheck SC2064は無効化する)。
    # shellcheck disable=SC2064
    trap "rm -rf '${clone_dir}'" EXIT

    echo "Cloning ${ZENGIN_PL_REPO} to verify ${target_sha}"
    clone_zengin_pl "$clone_dir"

    if ! commit_exists "$clone_dir" "$target_sha"; then
        echo "::error::commit ${target_sha} does not exist in ${ZENGIN_PL_REPO}" >&2
        exit 1
    fi

    if ! is_ancestor_of_master "$clone_dir" "$target_sha"; then
        echo "::error::commit ${target_sha} is not on ${ZENGIN_PL_REPO}'s master history" >&2
        exit 1
    fi

    if ! check_runs_all_success "$target_sha"; then
        echo "::error::${target_sha} does not have a fully successful Perl test matrix; refusing to pin an unverified commit" >&2
        exit 1
    fi

    echo "Verified: ${target_sha} is on master and passed CI"

    if ! write_ref_if_changed "$ZENGIN_PL_REF_FILE" "$target_sha"; then
        echo "zengin-pl.ref already pins ${target_sha}; nothing to do"
        exit 0
    fi

    local source_url
    source_url="$(representative_check_run_url "$target_sha")"
    source_url="${source_url:-https://github.com/${ZENGIN_PL_REPO}/commits/${target_sha}}"

    local branch title body_file
    branch="$(branch_name)"
    title="$(pr_title "$target_sha")"
    body_file="$(mktemp)"
    pr_body "$current_sha" "$target_sha" "$source_url" > "$body_file"

    git checkout -B "$branch"
    git add "$ZENGIN_PL_REF_FILE"
    git -c user.name="github-actions[bot]" -c user.email="github-actions[bot]@users.noreply.github.com" \
        commit -m "$(commit_message "$target_sha")"
    git push --force origin "HEAD:refs/heads/${branch}"

    ensure_update_pr "$branch" "$title" "$body_file"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
