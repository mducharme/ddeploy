#!/usr/bin/env bash
# `provision-all` / `deploy-all` — iterate ./manifest (name -> repo-url
# -> optional branch) so onboarding a server's whole site list is one
# command. Always non-interactive: a failing site is logged and skipped,
# not a blocker for the rest of the run.

read_manifest() {
    grep -vE '^\s*(#|$)' "$PROVISIONER_DIR/manifest" || true
}

cmd_provision_all() {
    load_conf
    [[ -f "$PROVISIONER_DIR/manifest" ]] || die "no ./manifest — copy manifest.example to manifest and fill it in first"
    local failures=0
    local line name repo_url branch
    local -a extra
    while IFS= read -r line; do
        name="$(awk '{print $1}' <<< "$line")"
        repo_url="$(awk '{print $2}' <<< "$line")"
        branch="$(awk '{print $3}' <<< "$line")"
        [[ -n "$name" ]] || continue
        log_info "== provision-all: $name =="
        extra=()
        [[ -n "$branch" ]] && extra=(--branch "$branch")
        if ! "$PROVISIONER_DIR/provision.sh" provision "$name" "$repo_url" --non-interactive \
                --php "$DEFAULT_PHP" "${extra[@]}"; then
            log_error "provision failed for $name"
            failures=$((failures + 1))
        fi
    done < <(read_manifest)
    [[ "$failures" -eq 0 ]] || die "$failures site(s) failed to provision"
}

cmd_deploy_all() {
    load_conf
    local failures=0
    local site_path name
    for site_path in "$SITES_ROOT"/*/; do
        [[ -d "$site_path" ]] || continue
        name="$(basename "$site_path")"
        is_provisioned "$name" || continue
        is_preview "$name" && continue   # has its own update path: deploy-preview
        log_info "== deploy-all: $name =="
        if ! "$PROVISIONER_DIR/provision.sh" deploy "$name"; then
            log_error "deploy failed for $name"
            failures=$((failures + 1))
        fi
    done
    [[ "$failures" -eq 0 ]] || die "$failures site(s) failed to deploy"
}
