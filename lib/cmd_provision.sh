#!/usr/bin/env bash
# `provision <name> [repo-url]` — clone if absent, resolve config (ddev /
# sidecar / interactive / flags), stand up the isolated native vhost, run
# the first deploy.

usage_provision() {
    cat <<'EOF'
usage: ddeploy provision <name> [repo-url] [options]

options:
  --non-interactive        never prompt; error if required info is missing
                            and no .ddev/config.yaml / sidecar exists
  --php <version>           e.g. 8.2 (non-interactive fallback field)
  --docroot <path>          relative to repo root (non-interactive fallback field)
  --branch <name>           track this branch instead of whatever the remote's
                            default is (first clone) or whatever's already
                            checked out (an existing site) — persists as an
                            operator-side setting, so the next deploy
                            switches to it; see README "Default branch";
                            always overrides config (there is no config
                            equivalent — this is never read from the repo)
  --clear-branch            remove a --branch override, going back to
                            whatever branch is already checked out
  --db <name>                DB name and user; always overrides config
  --hostnames "<a> <b>"     space-separated additional hostnames; always
                            overrides config
  --custom-domains "<a> <b>"  space-separated custom domains (this site's own
                            domain, not <name>.<base domain> — see README);
                            always overrides config
  --upload-dirs "<a> <b>"   space-separated dirs (relative to docroot, same as
                            DDEV's own upload_dirs — "../foo" is fine for a
                            private dir just outside it) to back up to object
                            storage, if enabled — see README; always
                            overrides config
  --deploy-cmd <cmd>        repeatable; each becomes an exec step after
                            composer install; always overrides config
                            (replaces hooks.post-start from .ddev or
                            .ddeploy, not merged with them; .ddeploy's
                            hooks.post-deploy/post-provision still run)
  --auth                    force basic auth on for this site
  --no-auth                 force basic auth off for this site
  --node <version>          pin this site's Node version (22, 22.11.0, lts/*);
                            saved as an operator override (`override`), so
                            it wins over nodejs_version/.nvmrc on every
                            later deploy too — `override <name> --unset
                            nodejs_version` to drop it
  --no-build                turn this site's frontend build off (saved as
                            override build=false)
  --build                   undo --no-build (back to the repo's own build:
                            or auto-detection)
EOF
}

# EXIT trap for a first provision whose clone failed: removes the site
# directory, and the www-<name> user if this run created it ($2 = 1;
# 2 means the user already existed and is kept).
provision_undo_fresh() {
    local name="$1" created="$2"
    rm -rf "${SITES_ROOT:?}/$name"
    if [[ "$created" == "1" ]]; then
        userdel "www-$name" 2>/dev/null || true
    fi
    log_info "cleaned up '$name' — the clone failed, so nothing was provisioned"
}

cmd_provision() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_provision; return 0; }

    load_conf
    require_root
    local started="$SECONDS"

    local name="${1:-}"
    if [[ -n "$name" ]]; then
        shift
    fi
    [[ -n "$name" ]] || { usage_provision; die "site name required"; }
    validate_name "$name"

    local repo_url="" non_interactive=0
    local opt_php="" opt_docroot="" opt_db="" opt_hostnames="" opt_custom_domains="" opt_upload_dirs="" opt_deploy_cmds="" opt_branch="" opt_clear_branch=0 auth_flag=""
    local opt_node="" opt_build=""

    if [[ "${1:-}" != "" && "${1:-}" != --* ]]; then
        repo_url="$1"; shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive) non_interactive=1 ;;
            --php) opt_php="$2"; shift ;;
            --docroot) opt_docroot="$2"; shift ;;
            --branch) opt_branch="$2"; shift ;;
            --clear-branch) opt_clear_branch=1 ;;
            --db) opt_db="$2"; shift ;;
            --hostnames) opt_hostnames="$2"; shift ;;
            --custom-domains) opt_custom_domains="$2"; shift ;;
            --upload-dirs) opt_upload_dirs="$2"; shift ;;
            --deploy-cmd) opt_deploy_cmds="${opt_deploy_cmds}${2}"$'\n'; shift ;;
            --auth) auth_flag="true" ;;
            --no-auth) auth_flag="false" ;;
            --node) opt_node="$2"; shift ;;
            --no-build) [[ "$opt_build" != "true" ]] || die "--build and --no-build are mutually exclusive"; opt_build="false" ;;
            --build) [[ "$opt_build" != "false" ]] || die "--build and --no-build are mutually exclusive"; opt_build="true" ;;
            -h|--help) usage_provision; return 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done

    [[ -n "$opt_branch" && "$opt_clear_branch" -eq 1 ]] && die "--branch and --clear-branch are mutually exclusive"
    if [[ -n "$opt_node" ]]; then
        [[ "$opt_node" == "lts" ]] && opt_node="lts/*"
        validate_node_version_spec "$opt_node" "--node"
    fi

    local wrapper; wrapper="$(site_root "$name")"
    local dir dest

    # Before anything is created on disk: a typo'd name with no repo URL
    # must not leave a directory and a Linux user behind.
    if [[ ! -d "$(site_dir "$name")/.git" && -z "$repo_url" ]]; then
        die "'$name' isn't provisioned yet — give its repo URL: ddeploy provision $name <repo-url>"
    fi

    # A first provision whose clone fails (wrong URL, no access) undoes
    # the directory and user it just created, so nothing is left behind
    # to trip up the next attempt. Only what this run created: a re-run
    # on an existing site never removes anything.
    local fresh=0
    if [[ ! -e "$wrapper" ]]; then
        fresh=1
        if id -u "www-$name" >/dev/null 2>&1; then
            fresh=2
        fi
    fi

    # Home dir for useradd; the wrapper is created by the clone below.
    # Must exist as a user before lock_site_root (called from
    # ensure_releases_layout) chowns the wrapper to that group.
    mkdir -p "$wrapper"
    ensure_site_user "$name" "$wrapper"

    if [[ ! -d "$(site_dir "$name")/.git" ]]; then
        if [[ "$fresh" -ne 0 ]]; then
            # $name is validate_name-clean, safe to splice into the trap.
            trap "provision_undo_fresh $name $fresh" EXIT
        fi
        dest="$(clone_into_release "$name" "$repo_url" "$opt_branch")"
        switch_current "$name" "$dest"
        trap - EXIT
    fi

    # Persists regardless of whether this was a first clone or a re-run
    # on an already-provisioned site — the latter is how an operator
    # points an existing site at a different branch: no repo commit, the
    # next deploy just picks it up. See README "Default branch".
    if [[ -n "$opt_branch" ]]; then
        write_deploy_branch "$name" "$opt_branch"
    elif [[ "$opt_clear_branch" -eq 1 ]]; then
        clear_deploy_branch "$name"
    fi

    ensure_releases_layout "$name"
    dir="$(site_dir "$name")"
    dest="$(current_release_real "$name")"
    [[ -n "$dest" ]] || dest="$dir"
    git_trust_repo "$dir"
    git_trust_repo "$dest"

    local cfg_path; cfg_path="$(resolve_config_path "$name")"

    if [[ -z "$cfg_path" ]]; then
        if [[ "$non_interactive" -eq 1 ]]; then
            [[ -n "$opt_php" ]] || die "--non-interactive: no config found and --php not given"
            non_interactive_config "$name" "$opt_php" "$opt_docroot" "${opt_db:-$name}" "${opt_db:-$name}" "$opt_hostnames" "$opt_deploy_cmds" "$opt_custom_domains" "$opt_upload_dirs"
        else
            interactive_fallback "$name"
        fi
        cfg_path="$GENERATED_DIR/$name.yaml"
    fi

    # Persisted as operator overrides (lib/cmd_override.sh), not one-off
    # flags: a later plain `deploy` has to keep honoring them.
    if [[ -n "$opt_node" ]]; then
        override_set_scalar "$name" nodejs_version "$opt_node"
        log_info "'$name': node pinned to $opt_node (operator override)"
    fi
    if [[ "$opt_build" == "false" ]]; then
        override_set_scalar "$name" build false
        log_info "'$name': frontend build turned off (operator override)"
    elif [[ "$opt_build" == "true" ]]; then
        override_unset_key "$name" build
        log_info "'$name': frontend build override removed"
    fi

    if [[ -n "$opt_db" ]]; then
        DB_NAME_OVERRIDE="$opt_db"
        DB_USER_OVERRIDE="$opt_db"
    fi
    [[ -n "$opt_hostnames" ]] && ADDITIONAL_HOSTNAMES_OVERRIDE="$opt_hostnames"
    [[ -n "$opt_custom_domains" ]] && ADDITIONAL_FQDNS_OVERRIDE="$opt_custom_domains"
    [[ -n "$opt_upload_dirs" ]] && UPLOAD_DIRS_OVERRIDE="$opt_upload_dirs"
    [[ -n "$opt_deploy_cmds" ]] && DEPLOY_CMDS_OVERRIDE="$opt_deploy_cmds"
    parse_config "$name" "$cfg_path" 1

    log_info "resolved: php=$PHP_VERSION node=${NODE_VERSION_SPEC:--} build=$BUILD_ENABLED docroot='${DOCROOT}' hostnames=[${ADDITIONAL_HOSTNAMES[*]:-}]${DEPLOY_BRANCH:+ deploy_branch=$DEPLOY_BRANCH}"
    scan_hooks "$name"

    ensure_php_installed "$PHP_VERSION"
    lock_site_root "$name"
    apply_permissions "$name" "$dest"
    # Must run after apply_permissions (its chown/chmod would otherwise
    # walk right past the persistent store, which lives outside $dir —
    # not a problem, but ensure_persistent_link's own chown needs to run
    # after apply_permissions has settled ownership on $dir, not race it)
    # and before db_ensure below, so write_db_credentials writes through
    # an already-established symlink into the persistent store from the
    # very first write, not into a real file that then needs migrating.
    link_persistent_files "$name" "$dest"
    # Older ddeploy versions copied GIT_DEPLOY_KEY into this user's own
    # $HOME/.ssh here so composer/hook-replay could authenticate as
    # www-<name> — a standing copy of a fleet-wide key, readable by this
    # site's own (less trusted) user at any time, not just during a
    # deploy. That's now a transient per-deploy ssh-agent instead (see
    # start_deploy_ssh_agent below); wipe any leftover copy. Harmless
    # (and cheap) to run every time.
    rm -rf "$wrapper/.ssh"
    install_fpm_pool "$name" "$PHP_VERSION" "" "" "${FPM_MAX_CHILDREN_CONFIG:-$FPM_MAX_CHILDREN}"

    local root="$dir"
    [[ -n "$DOCROOT" ]] && root="$dir/$DOCROOT"
    local auth="${auth_flag:-${BASIC_AUTH_CONFIG:-$BASIC_AUTH_DEFAULT}}"
    local max_body_size="${CLIENT_MAX_BODY_SIZE_CONFIG:-$CLIENT_MAX_BODY_SIZE}"
    install_vhost "$name" "$root" "$auth" "$max_body_size" "${ADDITIONAL_HOSTNAMES[@]}"
    # A custom domain's HTTP-01 request routinely fails on first
    # provision (DNS not propagated yet) — that must not abort the rest
    # of setup: the site is already reachable at the wildcard domain
    # above, and a bare call here would otherwise kill the whole
    # provision run under set -e before db_ensure/hooks ever ran.
    if ! install_custom_domain_vhost "$name" "$root" "$auth" "$max_body_size" "${ADDITIONAL_FQDNS[@]}"; then
        log_warn "custom domain setup failed for '$name' — continuing with the rest of provisioning; re-run provision once DNS is ready to retry it"
    fi

    db_ensure "$name" "$dest"   # each scheme re-owns the file it writes itself
    seed_cms_env "$name" "$dest" "$DB_ENV_SCHEME" "https://$name.$BASE_DOMAIN"

    site_log "$name" "provision: started ($(notify_trigger)) — php=$PHP_VERSION docroot=${DOCROOT:-.} db=$DB_NAME ($DB_ENV_SCHEME), at $(git -C "$dest" log -1 --format='%h "%s"' | cut -c1-120)"

    log_info "running first deploy for $name"
    # Bracket just the hook-replay window with a live ssh-agent (see
    # lib/git_access.sh) — composer/exec steps may need it for a private
    # VCS dependency. Trap so a failing hook still tears the agent down.
    start_deploy_ssh_agent "www-$name"
    trap 'stop_deploy_ssh_agent' EXIT
    replay_hooks "$name" "$PHP_VERSION" "$dest" "www-$name" "$wrapper"
    replay_hooks "$name" "$PHP_VERSION" "$dest" "www-$name" "$wrapper" "$GENERATED_DIR/$name.provision-steps" provision
    run_repo_hook "$name" "$PHP_VERSION" "$dest" ".ddeploy/post-provision.sh" "post-provision script" "www-$name" "$wrapper"
    stop_deploy_ssh_agent
    trap - EXIT
    # $dir (current-based, stable), not $dest (the specific release
    # directory) — an ops hook that persists SITE_DIR for later
    # reference shouldn't be handed a path a future deploy will prune.
    run_ops_hooks "post-provision" "$name" "$dir" "$PHP_VERSION"

    # After hooks (composer install must have already run — a worker or
    # scheduled command almost always needs vendor/ to exist). $dir, not
    # $dest: same reasoning as run_ops_hooks above — this must keep
    # working after $dest itself is eventually pruned.
    install_queue_workers "$name" "$PHP_VERSION" "$dir" "www-$name" "www-$name" "$wrapper" "${QUEUE_WORKERS[@]}"
    install_schedule "$name" "$PHP_VERSION" "$dir" "www-$name" "$wrapper" "${SCHEDULE[@]}"
    # So `deploy --rollback` has something to walk back to even before a
    # single ordinary `deploy` has ever run against this site.
    record_deploy "$name" "$(git -C "$dest" log -1 --format=%H)"

    site_log "$name" "provision: done in $((SECONDS - started))s — https://$name.$BASE_DOMAIN" ok
    log_ok "provisioned: https://$name.$BASE_DOMAIN"
    local live; live="$(site_dir "$name")"
    event_attr to_sha "$(git -c safe.directory='*' -C "$live" log -1 --format=%H 2>/dev/null || true)"
    event_attr subject "$(git -c safe.directory='*' -C "$live" log -1 --format=%s 2>/dev/null | cut -c1-200 || true)"
    event_attr author "$(git -c safe.directory='*' -C "$live" log -1 --format=%an 2>/dev/null | cut -c1-100 || true)"
    event_attr branch "$(git -c safe.directory='*' -C "$live" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    local fqdn
    for fqdn in "${ADDITIONAL_FQDNS[@]}"; do
        log_info "  also: https://$fqdn"
    done
    notify_deploy_success deploy-success "$name" "$dir" "$((SECONDS - started))" "provisioned"
}
