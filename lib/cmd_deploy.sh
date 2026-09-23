#!/usr/bin/env bash
# `deploy <name>` — build a new release, re-apply vhost/FPM config, replay
# post-start hooks on the NEW tree, then atomically retarget `current`.
# This is the CI target: the pipeline's SSH command becomes
# `provision.sh deploy <name>`.
# `deploy <name> --rollback [<sha>]` retargets `current` at an earlier
# release instead — see lib/releases.sh, lib/deploy_history.sh, and
# usage_deploy below.

usage_deploy() {
    cat <<'EOF'
usage: provision.sh deploy <name> [--rollback [<sha>]]
       provision.sh deploy <name> --history

options:
  --rollback [<sha>]   instead of pulling, retarget `current` at <sha> (or,
                        if omitted, the most recent different commit this
                        tool has itself deployed). Hooks run only when a
                        new release directory has to be built. See README
                        "Rolling back" for what this does and does NOT
                        undo (database migrations are not reversed)
  --history             print this site's deploy history (newest last) and
                        exit — use a SHA from here with --rollback
EOF
}

cmd_deploy() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_deploy; return 0; }
    load_conf
    require_root

    local name="${1:-}"
    [[ -n "$name" ]] || { usage_deploy; die "site name required"; }
    shift || true
    validate_name "$name"

    if is_preview "$name"; then
        die "'$name' is a preview — use deploy-preview, not deploy"
    fi

    local rollback=0 rollback_sha="" history=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rollback)
                rollback=1
                if [[ -n "${2:-}" && "$2" != --* ]]; then rollback_sha="$2"; shift; fi
                ;;
            --history) history=1 ;;
            -h|--help) usage_deploy; return 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done

    ensure_releases_layout "$name"

    local wrapper; wrapper="$(site_root "$name")"
    local dir; dir="$(site_dir "$name")"
    [[ -d "$dir/.git" ]] || die "$dir is not a git repo — provision it first"

    if [[ "$history" -eq 1 ]]; then
        local f; f="$(deploy_history_path "$name")"
        if [[ -s "$f" ]]; then
            log_info "deploy history for '$name' (newest last):"
            while IFS=$'\t' read -r ts sha; do
                printf '  %s  %s\n' "$ts" "$(git -C "$dir" log -1 --format='%h %s' "$sha" 2>/dev/null || echo "$sha")"
            done < "$f"
        else
            log_info "no deploy history recorded for '$name' yet"
        fi
        return 0
    fi

    # See lib/cmd_provision.sh's identical cleanup — older ddeploy
    # versions copied GIT_DEPLOY_KEY into this user's own $HOME/.ssh;
    # wipe any leftover from before the per-deploy ssh-agent replaced it.
    rm -rf "$wrapper/.ssh"

    local current_sha; current_sha="$(git -C "$dir" log -1 --format=%H)"
    local dest run_hooks=1
    ROLLBACK_RELEASE_KIND=""

    if [[ "$rollback" -eq 1 ]]; then
        local target="$rollback_sha"
        if [[ -z "$target" ]]; then
            target="$(previous_deploy_sha "$name" "$current_sha")" \
                || die "no earlier deploy recorded for '$name' to roll back to — pass an explicit <sha> (see --history), or there simply isn't one yet"
        fi
        log_warn "rolling back '$name': $(git -C "$dir" log -1 --format=%h "$current_sha") -> $(git -C "$dir" log -1 --format=%h "$target") — this moves the CODE back only; any database migration already applied by a later deploy is NOT undone"
        dest="$(prepare_rollback_release "$name" "$target")"
        [[ "$ROLLBACK_RELEASE_KIND" == "existing" ]] && run_hooks=0
    else
        dest="$(prepare_forward_release "$name")"
    fi

    # Discard this release on any failure before switch_current, so a
    # broken hook cannot take the site down. Same trap also tears down
    # the per-deploy ssh-agent (lib/git_access.sh) if a hook fails partway
    # through — it must never outlive this one deploy call.
    NEW_RELEASE_DIR=""
    if [[ "$run_hooks" -eq 1 ]]; then
        NEW_RELEASE_DIR="$dest"
        start_deploy_ssh_agent "www-$name"
        trap '[[ -n "${NEW_RELEASE_DIR:-}" ]] && rm -rf "$NEW_RELEASE_DIR"; stop_deploy_ssh_agent' EXIT
    fi

    CONFIG_CHECKOUT_DIR="$dest"
    local cfg_path; cfg_path="$(resolve_config_path "$name")"
    [[ -n "$cfg_path" ]] || { unset CONFIG_CHECKOUT_DIR; die "no config for '$name' (no .ddev/config.yaml or generated sidecar) — run provision first"; }
    parse_config "$name" "$cfg_path" 1
    unset CONFIG_CHECKOUT_DIR

    apply_permissions "$name" "$dest"
    link_persistent_files "$name" "$dest"

    if [[ "$run_hooks" -eq 1 ]]; then
        scan_hooks "$name"
        replay_hooks "$name" "$PHP_VERSION" "$dest" "www-$name" "$wrapper"
        run_repo_hook "$name" "$PHP_VERSION" "$dest" ".provisioner/post-deploy.sh" "post-deploy script" "www-$name" "$wrapper"
    else
        log_info "skipping hook replay — retargeting an existing release that already ran them"
    fi

    switch_current "$name" "$dest"
    NEW_RELEASE_DIR=""
    [[ "$run_hooks" -eq 1 ]] && stop_deploy_ssh_agent
    trap - EXIT
    dir="$(site_dir "$name")"

    # Re-applied on every deploy, not just provision — php_version,
    # basic_auth, client_max_body_size, fpm_max_children, php_ini,
    # additional_hostnames/additional_fqdns, and the scoped nginx extras
    # (redirects, security_headers, static_cache, deny_php_in_uploads)
    # are all config an operator reasonably expects a deploy to pick up.
    # Reload after the swap so PHP's realpath cache drops the previous
    # release path.
    ensure_php_installed "$PHP_VERSION"
    install_fpm_pool "$name" "$PHP_VERSION" "" "" "${FPM_MAX_CHILDREN_CONFIG:-$FPM_MAX_CHILDREN}"
    local nginx_root="$dir"
    [[ -n "$DOCROOT" ]] && nginx_root="$dir/$DOCROOT"
    local auth="${BASIC_AUTH_CONFIG:-$BASIC_AUTH_DEFAULT}"
    local max_body_size="${CLIENT_MAX_BODY_SIZE_CONFIG:-$CLIENT_MAX_BODY_SIZE}"
    install_vhost "$name" "$nginx_root" "$auth" "$max_body_size" "${ADDITIONAL_HOSTNAMES[@]}"
    if ! install_custom_domain_vhost "$name" "$nginx_root" "$auth" "$max_body_size" "${ADDITIONAL_FQDNS[@]}"; then
        log_warn "custom domain setup failed for '$name' during deploy — continuing; re-run deploy once DNS is ready to retry it"
    fi

    # Unconditional, same as install_fpm_pool above — a rollback also
    # needs a persistent worker restarted onto the code it just
    # retargeted current at, even when replay_hooks itself was skipped.
    install_queue_workers "$name" "$PHP_VERSION" "$dir" "www-$name" "www-$name" "$wrapper" "${QUEUE_WORKERS[@]}"
    install_schedule "$name" "$PHP_VERSION" "$dir" "www-$name" "$wrapper" "${SCHEDULE[@]}"

    prune_old_releases "$name"

    # Root-run ops hooks (hooks/post-deploy.d/*.sh — operator concerns
    # like a reverse-proxy list or a success ping, per hooks/README.md)
    # fire here, after the swap, not alongside the repo's own build-time
    # hooks above — an ops hook wants to know the release is actually
    # live, and SITE_DIR should be the stable current-based path (still
    # valid after this release itself is eventually pruned), not the
    # specific release directory that was just staged. Unconditional
    # (not gated on $run_hooks): a rollback to an already-built release
    # still retargets current, which is the event these care about, even
    # though replay_hooks itself was skipped for it.
    run_ops_hooks "post-deploy" "$name" "$dir" "$PHP_VERSION"

    local full_sha; full_sha="$(git -C "$dir" log -1 --format=%H)"
    local sha; sha="$(git -C "$dir" log -1 --format=%h)"
    record_deploy "$name" "$full_sha"
    if [[ "$rollback" -eq 1 ]]; then
        site_log "$name" "rollback: done at $sha"
        log_info "rolled back $name @ $sha"
    else
        site_log "$name" "deploy: done at $sha"
        log_info "deployed $name @ $sha"
    fi
}
