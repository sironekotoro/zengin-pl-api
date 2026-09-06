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
#   - merge・auto-mergeは行わない。PR作成までが責務
#     (auto-merge自体はauto-merge-zengin-pl-pr.shが別workflowで行う)。
#
# 関数はunit test(t/06_sync_script.t)からsourceして個別に呼び出せるよう、
# ネットワーク/gitに依存する処理と純粋なロジックを分離している。
# zengin-pl側のSHA検証はbin/lib/zengin-pl-verify.shを共用する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/zengin-pl-verify.sh
source "${SCRIPT_DIR}/lib/zengin-pl-verify.sh"

ZENGIN_PL_REF_FILE="${ZENGIN_PL_REF_FILE:-zengin-pl.ref}"
SYNC_BRANCH="${SYNC_BRANCH:-chore/update-zengin-pl}"

# --- 純粋なロジック(network/git不要) ---

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
通常どおり実行され、Cloud Runへ自動deployされます。

このPRは条件を満たせば[auto-merge-zengin-pl.yml](.github/workflows/auto-merge-zengin-pl.yml)
により自動でmergeされます(author・branch・変更ファイル・diff形状・
zengin-pl/zengin-pl-api双方のCI結果などを再検証したうえで、全て満たした
場合のみ)。条件を満たさない場合はopenのまま残るので、その際は内容を
確認して人間がmergeしてください。
EOF
}

# --- git/gh に依存する処理 ---

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

    if ! verify_zengin_pl_sha "$clone_dir" "$target_sha"; then
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
