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
  --db <name>                DB name (and user, unless overridden by config)
  --hostnames "<a> <b>"     space-separated additional hostnames
  --deploy-cmd <cmd>        repeatable; each becomes an exec step after composer install
  --auth                    force basic auth on for this site
  --no-auth                 force basic auth off for this site
EOF
}

cmd_provision() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_provision; return 0; }

    load_conf
    require_root

    local name="${1:-}"; [[ -n "$name" ]] && shift || true
    [[ -n "$name" ]] || { usage_provision; die "site name required"; }
    validate_name "$name"

    local repo_url="" non_interactive=0
    local opt_php="" opt_docroot="" opt_db="" opt_hostnames="" opt_deploy_cmds="" auth_flag=""

    if [[ "${1:-}" != "" && "${1:-}" != --* ]]; then
        repo_url="$1"; shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive) non_interactive=1 ;;
            --php) opt_php="$2"; shift ;;
            --docroot) opt_docroot="$2"; shift ;;
            --db) opt_db="$2"; shift ;;
            --hostnames) opt_hostnames="$2"; shift ;;
            --deploy-cmd) opt_deploy_cmds="${opt_deploy_cmds}${2}"$'\n'; shift ;;
            --auth) auth_flag="true" ;;
            --no-auth) auth_flag="false" ;;
            -h|--help) usage_provision; return 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done

    local dir; dir="$(site_dir "$name")"

    if [[ ! -d "$dir" ]]; then
        [[ -n "$repo_url" ]] || die "no repo at $dir and no repo-url given"
        log_info "cloning $repo_url -> $dir"
        GIT_SSH_COMMAND="$(git_ssh_command)" git clone "$repo_url" "$dir"
    fi

    local cfg_path; cfg_path="$(resolve_config_path "$name")"

    if [[ -z "$cfg_path" ]]; then
        if [[ "$non_interactive" -eq 1 ]]; then
            [[ -n "$opt_php" ]] || die "--non-interactive: no config found and --php not given"
            non_interactive_config "$name" "$opt_php" "$opt_docroot" "${opt_db:-$name}" "${opt_db:-$name}" "$opt_hostnames" "$opt_deploy_cmds"
        else
            interactive_fallback "$name"
        fi
        cfg_path="$GENERATED_DIR/$name.yaml"
    fi

    if [[ -n "$opt_db" ]]; then
        DB_NAME_OVERRIDE="$opt_db"
        DB_USER_OVERRIDE="$opt_db"
    fi
    parse_config "$name" "$cfg_path" 1

    log_info "resolved: php=$PHP_VERSION docroot='${DOCROOT}' hostnames=[${ADDITIONAL_HOSTNAMES[*]:-}]"
    scan_hooks "$name"

    ensure_php_installed "$PHP_VERSION"
    ensure_site_user "$name" "$dir"
    apply_permissions "$name" "$dir"
    # Must come after apply_permissions (its 600/700 perms would
    # otherwise get clobbered by a later whole-tree chmod) and before
    # anything that might need repo access (hook replay, below, may run
    # `composer install` against a private VCS dependency).
    sync_site_ssh "$name" "$dir"
    install_fpm_pool "$name" "$PHP_VERSION"

    local root="$dir"
    [[ -n "$DOCROOT" ]] && root="$dir/$DOCROOT"
    local auth="${auth_flag:-$BASIC_AUTH_DEFAULT}"
    install_vhost "$name" "$root" "$auth" "${ADDITIONAL_HOSTNAMES[@]}"

    db_ensure "$name" "$dir"   # each scheme re-owns the file it writes itself

    site_log "$name" "provision: php=$PHP_VERSION docroot=$DOCROOT"

    log_info "running first deploy for $name"
    replay_hooks "$name" "$PHP_VERSION" "$dir"
    run_repo_hook "$name" "$PHP_VERSION" "$dir" ".provisioner/post-provision.sh" "post-provision script"
    run_ops_hooks "post-provision" "$name" "$dir" "$PHP_VERSION"

    log_info "provisioned: https://$name.$BASE_DOMAIN"
}
