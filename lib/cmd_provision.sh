#!/usr/bin/env bash
# `provision <name> [repo-url]` — clone if absent, resolve config (ddev /
# sidecar / interactive / flags), stand up the isolated native vhost, run
# the first deploy.

usage_provision() {
    cat <<'EOF'
usage: provision.sh provision <name> [repo-url] [options]

options:
  --non-interactive        never prompt; error if required info is missing
                            and no .ddev/config.yaml / sidecar exists
  --php <version>           e.g. 8.2 (non-interactive fallback field)
  --docroot <path>          relative to repo root (non-interactive fallback field)
  --branch <name>           clone this branch instead of the remote's default;
                            only affects the very first clone — see README
                            "Default branch" for changing it later via
                            deploy_branch: in .ddeploy/config.yaml
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
                            (replaces any hooks.post-start from config, not
                            merged with them)
  --auth                    force basic auth on for this site
  --no-auth                 force basic auth off for this site
EOF
}

cmd_provision() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_provision; return 0; }

    load_conf
    require_root

    local name="${1:-}"
    if [[ -n "$name" ]]; then
        shift
    fi
    [[ -n "$name" ]] || { usage_provision; die "site name required"; }
    validate_name "$name"

    local repo_url="" non_interactive=0
    local opt_php="" opt_docroot="" opt_db="" opt_hostnames="" opt_custom_domains="" opt_upload_dirs="" opt_deploy_cmds="" opt_branch="" auth_flag=""

    if [[ "${1:-}" != "" && "${1:-}" != --* ]]; then
        repo_url="$1"; shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive) non_interactive=1 ;;
            --php) opt_php="$2"; shift ;;
            --docroot) opt_docroot="$2"; shift ;;
            --branch) opt_branch="$2"; shift ;;
            --db) opt_db="$2"; shift ;;
            --hostnames) opt_hostnames="$2"; shift ;;
            --custom-domains) opt_custom_domains="$2"; shift ;;
            --upload-dirs) opt_upload_dirs="$2"; shift ;;
            --deploy-cmd) opt_deploy_cmds="${opt_deploy_cmds}${2}"$'\n'; shift ;;
            --auth) auth_flag="true" ;;
            --no-auth) auth_flag="false" ;;
            -h|--help) usage_provision; return 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done

    local wrapper; wrapper="$(site_root "$name")"
    local dir dest

    # Home dir for useradd; the wrapper is created by the clone below.
    # Must exist as a user before lock_site_root (called from
    # ensure_releases_layout) chowns the wrapper to that group.
    mkdir -p "$wrapper"
    ensure_site_user "$name" "$wrapper"

    if [[ ! -d "$(site_dir "$name")/.git" ]]; then
        [[ -n "$repo_url" ]] || die "no repo at $(site_dir "$name") and no repo-url given"
        dest="$(clone_into_release "$name" "$repo_url" "$opt_branch")"
        switch_current "$name" "$dest"
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

    if [[ -n "$opt_db" ]]; then
        DB_NAME_OVERRIDE="$opt_db"
        DB_USER_OVERRIDE="$opt_db"
    fi
    [[ -n "$opt_hostnames" ]] && ADDITIONAL_HOSTNAMES_OVERRIDE="$opt_hostnames"
    [[ -n "$opt_custom_domains" ]] && ADDITIONAL_FQDNS_OVERRIDE="$opt_custom_domains"
    [[ -n "$opt_upload_dirs" ]] && UPLOAD_DIRS_OVERRIDE="$opt_upload_dirs"
    [[ -n "$opt_deploy_cmds" ]] && DEPLOY_CMDS_OVERRIDE="$opt_deploy_cmds"
    parse_config "$name" "$cfg_path" 1

    log_info "resolved: php=$PHP_VERSION docroot='${DOCROOT}' hostnames=[${ADDITIONAL_HOSTNAMES[*]:-}]${DEPLOY_BRANCH:+ deploy_branch=$DEPLOY_BRANCH}"
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
    # Must come after apply_permissions (its 600/700 perms would
    # otherwise get clobbered by a later whole-tree chmod) and before
    # anything that might need repo access (hook replay, below, may run
    # `composer install` against a private VCS dependency). HOME is the
    # wrapper, not a release, so a swap doesn't drop the key.
    sync_site_ssh "$name" "$wrapper"
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

    site_log "$name" "provision: php=$PHP_VERSION docroot=$DOCROOT"

    log_info "running first deploy for $name"
    replay_hooks "$name" "$PHP_VERSION" "$dest" "www-$name" "$wrapper"
    run_repo_hook "$name" "$PHP_VERSION" "$dest" ".provisioner/post-provision.sh" "post-provision script" "www-$name" "$wrapper"
    # $dir (current-based, stable), not $dest (the specific release
    # directory) — an ops hook that persists SITE_DIR for later
    # reference shouldn't be handed a path a future deploy will prune.
    run_ops_hooks "post-provision" "$name" "$dir" "$PHP_VERSION"
    # So `deploy --rollback` has something to walk back to even before a
    # single ordinary `deploy` has ever run against this site.
    record_deploy "$name" "$(git -C "$dest" log -1 --format=%H)"

    log_info "provisioned: https://$name.$BASE_DOMAIN"
    local fqdn
    for fqdn in "${ADDITIONAL_FQDNS[@]}"; do
        log_info "  also: https://$fqdn"
    done
}
