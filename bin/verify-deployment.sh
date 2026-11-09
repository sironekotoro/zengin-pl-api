#!/usr/bin/env bash
# Verify the public response after rollout, without trusting a cached /api/meta.
set -euo pipefail

verify_deployment() {
    local url="$1" expected="$2"
    local attempts="${VERIFY_ATTEMPTS:-12}" delay="${VERIFY_DELAY_SECONDS:-5}"
    [[ "$url" =~ ^https://[^/?\#]+/?$ ]] || { echo 'expected an HTTPS service origin' >&2; return 1; }
    [[ "$expected" =~ ^[0-9a-f]{40}$ ]] || { echo 'invalid expected deployment SHA' >&2; return 1; }
    [[ "$attempts" =~ ^[0-9]+$ && "$delay" =~ ^[0-9]+$ ]] || return 1
    (( attempts >= 2 && attempts <= 30 && delay <= 10 )) || return 1
    local attempt body observed consecutive=0
    for ((attempt=1; attempt<=attempts; attempt++)); do
        observed=unavailable
        if body="$(curl --proto '=https' --proto-redir '=https' --location --fail --silent --show-error \
            --connect-timeout 5 --max-time 15 --header 'Cache-Control: no-cache, no-store' \
            --header 'Pragma: no-cache' \
            "${url%/}/api/meta?verify_deploy=${expected}-${attempt}-$(date +%s)-${RANDOM}")"; then
            observed="$(jq -er '.api.git_sha | strings | select(test("^[0-9a-f]{40}$"))' <<<"$body")" || observed=invalid_metadata
        fi
        if [[ "$observed" == "$expected" ]]; then
            consecutive=$((consecutive + 1))
            if (( consecutive >= 2 )); then
                printf 'Verified deployed api.git_sha=%s in two consecutive uncached responses\n' "$expected"
                return 0
            fi
        else
            consecutive=0
        fi
        printf 'Deployment verification %s/%s: expected %s, observed %s\n' "$attempt" "$attempts" "$expected" "$observed" >&2
        if (( attempt < attempts )); then sleep "$delay"; fi
    done
    echo 'Deployment verification exhausted its retry budget; inspect Cloud Run rollout/traffic and /api/meta before retrying. No rollback was attempted.' >&2
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    [[ $# -eq 2 ]] || { echo "Usage: $0 HTTPS_SERVICE_ORIGIN EXPECTED_SHA" >&2; exit 1; }
    verify_deployment "$@"
fi
