#!/usr/bin/env bash
# `provision-preview` / `deploy-preview` / `remove-preview` / `prune-previews`
# — branch preview environments. See lib/preview.sh for the shared/isolated
# DB model these build on, and resolve_preview_config, which all three
# commands call fresh each time so they can never resolve differently.

usage_provision_preview() {
    cat <<'EOF'
usage: provision.sh provision-preview <project> <branch> [repo-url] [options]

<name> is derived deterministically from <project>+<branch> (see
preview_slug in lib/preview.sh) — deploy-preview/remove-preview take the
same (project, branch) pair and resolve the same name, no state to track.

options:
  --shared / --isolated   override PREVIEW_DB_MODE for this preview
  --seed / --no-seed      isolated mode only: seed DB+uploads from the
                          parent project once, at creation (default: on)
  --auth / --no-auth      basic auth (default: on for previews, unlike
                          normal sites — see BASIC_AUTH_DEFAULT)
EOF
}

usage_remove_preview() {
    cat <<'EOF'
usage: provision.sh remove-preview <project> <branch> [--purge-db] [--purge-files]

--purge-db is only honored for an isolated-mode preview (it has its own
database to drop); for a shared-mode preview it's a no-op — that
database belongs to the parent project. --purge-files always removes
just the preview's own checkout, never anything reached through the
shared-uploads symlink.
EOF
}

cmd_provision_preview() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_provision_preview; return 0; }
    load_conf
    require_root

    local project="${1:-}" branch="${2:-}"
    [[ -n "$project" && -n "$branch" ]] || { usage_provision_preview; die "project and branch required"; }
    shift 2

    local repo_url=""
    if [[ "${1:-}" != "" && "${1:-}" != --* ]]; then
        repo_url="$1"; shift
    fi

    local mode="$PREVIEW_DB_MODE" seed="$PREVIEW_SEED" auth_flag=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --shared) mode="shared" ;;
            --isolated) mode="isolated" ;;
            --seed) seed="true" ;;
            --no-seed) seed="false" ;;
            --auth) auth_flag="true" ;;
            --no-auth) auth_flag="false" ;;
            -h|--help) usage_provision_preview; return 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done

    validate_name "$project"
    local name; name="$(preview_slug "$project" "$branch")"
    validate_name "$name"
    [[ "$name" != "$project" ]] || die "project '$project' + branch '$branch' resolved to the project's own name — pick a different branch"

    local dir; dir="$(site_dir "$name")"
    local project_dir; project_dir="$(site_dir "$project")"

    if [[ "$mode" == "shared" ]]; then
        is_provisioned "$project" || die "shared mode needs '$project' to already be provisioned (it's the database/uploads this preview links to)"
        id -u "www-$project" >/dev/null 2>&1 || die "shared mode needs '$project's Linux user (www-$project) to exist"
    fi

    if [[ ! -d "$dir" ]]; then
        if [[ -z "$repo_url" ]]; then
            [[ -d "$project_dir/.git" ]] || die "no repo at $dir, no repo-url given, and '$project' isn't cloned to infer one from"
            repo_url="$(git -C "$project_dir" remote get-url origin)"
        fi
        log_info "cloning $repo_url (branch $branch) -> $dir"
        GIT_SSH_COMMAND="$(git_ssh_command)" git clone --branch "$branch" --single-branch "$repo_url" "$dir"
    fi

    resolve_preview_config "$name" "$project" "$mode"
    log_info "resolved: mode=$mode php=$PHP_VERSION docroot='${DOCROOT}'"
    scan_hooks "$name"
    ensure_php_installed "$PHP_VERSION"

    local exec_user exec_home pool_user pool_group
    if [[ "$mode" == "shared" ]]; then
        exec_user="www-$project"; exec_home="$project_dir"
        pool_user="www-$project"; pool_group="www-$project"
        apply_permissions "$name" "$dir" "$pool_user"
        link_shared_uploads "$dir" "$project_dir" "${UPLOAD_DIRS[@]}"
    else
        ensure_site_user "$name" "$dir"
        exec_user="www-$name"; exec_home="$dir"
        pool_user="www-$name"; pool_group="www-$name"
        apply_permissions "$name" "$dir"
        sync_site_ssh "$name" "$dir"
    fi

    install_fpm_pool "$name" "$PHP_VERSION" "$pool_user" "$pool_group"

    local root="$dir"
    [[ -n "$DOCROOT" ]] && root="$dir/$DOCROOT"
    local auth="${auth_flag:-true}"
    install_vhost "$name" "$root" "$auth" "${ADDITIONAL_HOSTNAMES[@]}"

    if [[ "$mode" == "shared" ]]; then
        link_shared_database "$name" "$dir" "$project" "$project_dir" "$DB_ENV_SCHEME"
    else
        db_ensure "$name" "$dir"
        if [[ "$seed" == "true" ]]; then
            if [[ -n "$PREVIEW_PROJECT_DB_NAME" ]]; then
                seed_preview_database "$PREVIEW_PROJECT_DB_NAME" "$DB_NAME"
                seed_preview_uploads "$dir" "$project_dir" "${UPLOAD_DIRS[@]}"
            else
                log_info "seed requested but '$project' isn't provisioned yet — leaving '$name' empty"
            fi
        fi
    fi

    write_preview_meta "$name" "$project" "$branch" "$mode"
    site_log "$name" "provision-preview: project=$project branch=$branch mode=$mode"

    log_info "running first deploy for $name"
    replay_hooks "$name" "$PHP_VERSION" "$dir" "$exec_user" "$exec_home"
    run_repo_hook "$name" "$PHP_VERSION" "$dir" ".provisioner/post-provision.sh" "post-provision script" "$exec_user" "$exec_home"
    run_ops_hooks "post-provision" "$name" "$dir" "$PHP_VERSION"

    log_info "provisioned preview ($mode): https://$name.$BASE_DOMAIN"
}

cmd_deploy_preview() {
    load_conf
    require_root

    local project="${1:-}" branch="${2:-}"
    [[ -n "$project" && -n "$branch" ]] || die "usage: provision.sh deploy-preview <project> <branch>"

    local name; name="$(preview_slug "$project" "$branch")"
    local dir; dir="$(site_dir "$name")"
    [[ -d "$dir/.git" ]] || die "$dir is not a git repo — provision-preview it first"
    read_preview_meta "$name" || die "'$name' has no preview metadata — was it created with provision-preview?"

    local exec_user="www-$name" exec_home="$dir"
    if [[ "$PREVIEW_MODE" == "shared" ]]; then
        exec_user="www-$PREVIEW_PROJECT"
        exec_home="$(site_dir "$PREVIEW_PROJECT")"
    else
        sync_site_ssh "$name" "$dir"
    fi

    # fetch + hard reset, not --ff-only pull: PR branches get rebased and
    # force-pushed routinely, and there's nothing local worth protecting
    # on a preview.
    log_info "git fetch + reset --hard origin/$PREVIEW_BRANCH ($name)"
    sudo -u "$exec_user" env HOME="$exec_home" git -C "$dir" fetch origin "$PREVIEW_BRANCH" 2>&1 | tee -a "$LOG_DIR/$name.log"
    sudo -u "$exec_user" env HOME="$exec_home" git -C "$dir" reset --hard "origin/$PREVIEW_BRANCH" 2>&1 | tee -a "$LOG_DIR/$name.log"

    resolve_preview_config "$name" "$PREVIEW_PROJECT" "$PREVIEW_MODE"
    scan_hooks "$name"
    replay_hooks "$name" "$PHP_VERSION" "$dir" "$exec_user" "$exec_home"
    run_repo_hook "$name" "$PHP_VERSION" "$dir" ".provisioner/post-deploy.sh" "post-deploy script" "$exec_user" "$exec_home"
    run_ops_hooks "post-deploy" "$name" "$dir" "$PHP_VERSION"

    systemctl reload "php${PHP_VERSION}-fpm" 2>/dev/null || true
    nginx -t && systemctl reload nginx

    local sha; sha="$(git -C "$dir" log -1 --format=%h)"
    site_log "$name" "deploy-preview: done at $sha"
    log_info "deployed preview $name @ $sha"
}

cmd_remove_preview() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_remove_preview; return 0; }
    load_conf
    require_root

    local project="${1:-}" branch="${2:-}"
    [[ -n "$project" && -n "$branch" ]] || { usage_remove_preview; die "project and branch required"; }
    shift 2

    local purge_db=0 purge_files=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge-db) purge_db=1 ;;
            --purge-files) purge_files=1 ;;
            -h|--help) usage_remove_preview; return 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done

    local name; name="$(preview_slug "$project" "$branch")"
    local dir; dir="$(site_dir "$name")"
    local mode="isolated"
    if read_preview_meta "$name"; then
        mode="$PREVIEW_MODE"
    else
        log_warn "'$name' has no preview metadata — removing it as best-effort anyway"
    fi

    remove_vhost "$name"
    remove_custom_domain_vhost "$name"

    # resolve_preview_config can die() if neither the preview's own nor
    # the parent's config resolves — removal has to stay robust even in
    # a half-broken state, so only call it once at least one is known to
    # resolve (mirroring its own internal condition for not dying).
    if [[ -n "$(resolve_config_path "$name")" || -n "$(resolve_config_path "$project")" ]]; then
        resolve_preview_config "$name" "$project" "$mode"
        remove_fpm_pool "$name" "$PHP_VERSION"
    else
        log_warn "no config found for '$name' or '$project' — skipping FPM pool removal (remove it manually under /etc/php/*/fpm/pool.d/ if needed)"
    fi

    if [[ "$purge_db" -eq 1 ]]; then
        if [[ "$mode" == "shared" ]]; then
            log_info "shared-mode preview — its database belongs to '$project', not dropping it"
        else
            db_drop "${DB_NAME:-$name}" "${DB_USER:-$name}"
            rm -f "$GENERATED_DIR/$name.dbpass"
        fi
    fi

    if [[ "$purge_files" -eq 1 ]]; then
        # A shared-mode preview's uploads paths are symlinks INTO the
        # parent's directory — rm -rf on the preview's own dir removes
        # the symlinks themselves, never what they point to.
        rm -rf "$dir"
        rm -f "$GENERATED_DIR/$name.yaml" "$GENERATED_DIR/$name.steps"
        if [[ "$mode" != "shared" ]]; then
            id -u "www-$name" >/dev/null 2>&1 && userdel "www-$name" 2>/dev/null || true
        fi
        log_info "removed preview $name"
    fi

    rm -f "$GENERATED_DIR/$name.preview"
    site_log "$name" "removed preview (purge_db=$purge_db purge_files=$purge_files)"
}

# Compares every provisioned preview against its branch's actual remote
# state and removes ones whose branch is gone. $1 (optional): only prune
# previews of this project.
cmd_prune_previews() {
    load_conf
    require_root

    local only_project="${1:-}" failures=0
    local f name
    for f in "$GENERATED_DIR"/*.preview; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f" .preview)"
        read_preview_meta "$name" || continue
        [[ -z "$only_project" || "$only_project" == "$PREVIEW_PROJECT" ]] || continue

        local dir; dir="$(site_dir "$name")"
        [[ -d "$dir/.git" ]] || continue
        local remote; remote="$(git -C "$dir" remote get-url origin 2>/dev/null)"
        [[ -n "$remote" ]] || continue

        # --exit-code returns 2 specifically for "connected fine, ref not
        # found" — any other nonzero (network blip, auth failure, host
        # down) means we couldn't actually check, and must NOT be treated
        # as "branch is gone": that would purge an active preview's
        # database/files on a false positive from a transient failure.
        local ls_remote_exit
        if git ls-remote --exit-code --heads "$remote" "$PREVIEW_BRANCH" >/dev/null 2>&1; then
            ls_remote_exit=0
        else
            ls_remote_exit=$?
        fi
        if [[ "$ls_remote_exit" -eq 0 ]]; then
            continue
        elif [[ "$ls_remote_exit" -ne 2 ]]; then
            log_warn "prune: couldn't check '$PREVIEW_BRANCH' on $remote (git exit $ls_remote_exit) — leaving preview '$name' alone this run"
            continue
        fi

        log_info "prune: '$PREVIEW_BRANCH' no longer exists on $remote — removing preview '$name'"
        # One preview failing to remove cleanly must not stop the rest
        # from being pruned this run — a bare call here would abort the
        # whole loop under set -e.
        if ! cmd_remove_preview "$PREVIEW_PROJECT" "$PREVIEW_BRANCH" --purge-db --purge-files; then
            log_error "prune: failed to remove preview '$name'"
            failures=$((failures + 1))
        fi
    done
    [[ "$failures" -eq 0 ]] || die "$failures preview(s) failed to remove"
}
