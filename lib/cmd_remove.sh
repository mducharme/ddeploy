#!/usr/bin/env bash
# `remove <name> [--purge-db] [--purge-files] [--purge-persistent]` —
# never destructive by default: only disables the vhost/pool. Files, DB,
# and persistent store all survive unless explicitly told to go.

usage_remove() {
    cat <<'EOF'
usage: provision.sh remove <name> [--purge-db] [--purge-files] [--purge-persistent]

By default only disables/removes the vhost and FPM pool. Add --purge-db
to drop the database and DB user, --purge-files to delete the site
directory and its Linux user, --purge-persistent to also delete its
persistent store (upload_dirs, DB credentials, persistent_files — see
README "Persistent files"). None of the three is implied by the others —
a plain --purge-files leaves the persistent store in place, so a later
`provision` on the same name picks its data back up automatically.
EOF
}

cmd_remove() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_remove; return 0; }

    load_conf
    require_root

    local name="${1:-}"
    if [[ -n "$name" ]]; then
        shift
    fi
    [[ -n "$name" ]] || { usage_remove; die "site name required"; }
    validate_name "$name"

    if is_preview "$name"; then
        read_preview_meta "$name"
        log_info "'$name' is a preview of '$PREVIEW_PROJECT' (branch '$PREVIEW_BRANCH') — delegating to remove-preview"
        cmd_remove_preview "$PREVIEW_PROJECT" "$PREVIEW_BRANCH" "$@"
        return $?
    fi

    local purge_db=0 purge_files=0 purge_persistent=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge-db) purge_db=1 ;;
            --purge-files) purge_files=1 ;;
            --purge-persistent) purge_persistent=1 ;;
            -h|--help) usage_remove; return 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done

    # The wrapper, not `current`: rm -rf on a symlink would delete only
    # the link and leave releases/ behind.
    local dir; dir="$(site_root "$name")"

    # Removal has to stay robust even if nginx -t fails for an unrelated
    # reason (e.g. another vhost hand-edited elsewhere) — a bare call
    # here would otherwise abort the rest of removal under set -e.
    remove_vhost "$name" || log_warn "removing the vhost for '$name' hit an error — continuing with the rest of removal"
    remove_custom_domain_vhost "$name" || log_warn "removing the custom-domain vhost for '$name' hit an error — continuing with the rest of removal"
    # Code-associated infra, like the vhost/FPM pool above — never
    # gated behind --purge-*, and doesn't need a config to be readable
    # (globs by name, same as remove_fpm_pool doesn't need config either).
    remove_all_queue_workers "$name" || log_warn "removing queue workers for '$name' hit an error — continuing with the rest of removal"
    remove_schedule "$name"

    local ver=""
    local cfg_path; cfg_path="$(resolve_config_path "$name")"
    if [[ -n "$cfg_path" ]]; then
        parse_config "$name" "$cfg_path" 0
        ver="$PHP_VERSION"
        remove_fpm_pool "$name" "$ver"
    else
        log_warn "no config found for '$name' — skipping FPM pool removal (remove it manually under /etc/php/*/fpm/pool.d/ if needed)"
    fi

    if [[ "$purge_db" -eq 1 ]]; then
        db_drop "${DB_NAME:-$name}" "${DB_USER:-$name}"
        rm -f "$GENERATED_DIR/$name.dbpass"
    else
        log_info "leaving database in place (pass --purge-db to drop it)"
    fi

    if [[ "$purge_files" -eq 1 ]]; then
        rm -rf "$dir"
        rm -f "$GENERATED_DIR/$name.yaml" "$GENERATED_DIR/$name.steps" "$(deploy_history_path "$name")"
        if id -u "www-$name" >/dev/null 2>&1; then
            userdel "www-$name" 2>/dev/null || true
        fi
        log_info "removed site directory and user for $name"
    else
        log_info "leaving site files in place (pass --purge-files to delete them)"
    fi

    if [[ "$purge_persistent" -eq 1 ]]; then
        rm -rf "${PERSISTENT_ROOT:?}/$name"
        log_info "removed persistent store for $name"
    else
        log_info "leaving persistent store in place (pass --purge-persistent to delete it) — a later provision picks its data back up"
    fi

    site_log "$name" "removed (purge_db=$purge_db purge_files=$purge_files purge_persistent=$purge_persistent)"
}
