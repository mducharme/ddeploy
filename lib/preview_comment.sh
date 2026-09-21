#!/usr/bin/env bash
# After a successful webhook preview upsert, post (or update) a comment
# on the PR with https://<slug>.$BASE_DOMAIN. Off unless
# PREVIEW_COMMENT_CREDENTIALS points at a chmod 600 file. Failure here
# must not fail the deploy — same rule as notify_failure.
#
# Repo is taken from the job's already-canonical repo_urls (github.com/
# or bitbucket.org/), never from an unvalidated full_name field. PR id
# is digits-only. Tokens stay in env for the Python helper, never argv.

PREVIEW_COMMENT_MARKER='<!-- ddeploy-preview -->'

# Prints owner/repo from canonical host/path urls if a $1 host matches.
preview_comment_repo_from_urls() {
    local host="$1"; shift
    local u rest
    for u in "$@"; do
        [[ "$u" == "$host"/* ]] || continue
        rest="${u#"$host"/}"
        [[ "$rest" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || continue
        printf '%s\n' "$rest"
        return 0
    done
    return 1
}

# $1 provider (github|bitbucket)  $2 preview site name  $3 PR id
# remaining args: canonical repo_urls from the job.
comment_preview_pr() {
    local provider="$1" name="$2" pr="$3"
    shift 3
    [[ -n "${PREVIEW_COMMENT_CREDENTIALS:-}" ]] || return 0
    [[ -f "$PREVIEW_COMMENT_CREDENTIALS" ]] || {
        log_warn "PREVIEW_COMMENT_CREDENTIALS is set but the file is missing — skipping PR comment"
        return 0
    }
    [[ "$provider" == "github" || "$provider" == "bitbucket" ]] || return 0
    [[ "$pr" =~ ^[1-9][0-9]{0,9}$ ]] || return 0
    [[ "$name" =~ $NAME_RE ]] || return 0

    local host repo
    case "$provider" in
        github)    host="github.com" ;;
        bitbucket) host="bitbucket.org" ;;
    esac
    repo="$(preview_comment_repo_from_urls "$host" "$@")" || {
        log_info "preview comment: no $host repo url in the job — skipping"
        return 0
    }

    local url="https://$name.$BASE_DOMAIN"
    local body
    body="$(printf '%s\nPreview: %s\n' "$PREVIEW_COMMENT_MARKER" "$url")"

    # Subshell so sourced tokens cannot leak into hook-worker's later jobs.
    local st=0
    (
        # shellcheck source=/dev/null
        source "$PREVIEW_COMMENT_CREDENTIALS"
        DDEPLOY_COMMENT_BODY="$body" \
            DDEPLOY_GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
            DDEPLOY_GITHUB_API="${GITHUB_API:-}" \
            DDEPLOY_BITBUCKET_USER="${BITBUCKET_USER:-}" \
            DDEPLOY_BITBUCKET_PASSWORD="${BITBUCKET_APP_PASSWORD:-}" \
            DDEPLOY_BITBUCKET_TOKEN="${BITBUCKET_TOKEN:-}" \
            DDEPLOY_BITBUCKET_API="${BITBUCKET_API:-}" \
            python3 "$PROVISIONER_DIR/lib/preview_comment.py" "$provider" "$repo" "$pr"
    ) || st=$?
    if [[ "$st" -eq 0 ]]; then
        log_info "preview comment: $provider PR $pr → $url"
    elif [[ "$st" -eq 2 ]]; then
        log_info "preview comment: no $provider token configured — skipping"
    else
        log_warn "preview comment: $provider PR $pr failed — check PREVIEW_COMMENT_CREDENTIALS (token is not logged)"
    fi
    return 0
}
