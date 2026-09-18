#!/usr/bin/env bash
# `remove <name> [--purge-db] [--purge-files]` — never destructive by
# default: only disables the vhost/pool. Files and DB survive unless
# explicitly told to go.

usage_remove() {
    cat <<'EOF'
usage: provision.sh remove <name> [--purge-db] [--purge-files]

By default only disables/removes the vhost and FPM pool. Add --purge-db
to drop the database and DB user, --purge-files to delete the site
directory and its Linux user. Neither is implied by the other.
EOF
}

cmd_remove() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_remove; return 0; }

    load_conf
    require_root

    local name="${1:-}"; [[ -n "$name" ]] && shift || true
    [[ -n "$name" ]] || { usage_remove; die "site name required"; }
    validate_name "$name"

    local purge_db=0 purge_files=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge-db) purge_db=1 ;;
            --purge-files) purge_files=1 ;;
            -h|--help) usage_remove; return 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done

    local dir; dir="$(site_dir "$name")"

    remove_vhost "$name"
    remove_custom_domain_vhost "$name"

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
        rm -f "$GENERATED_DIR/$name.yaml" "$GENERATED_DIR/$name.steps"
        id -u "www-$name" >/dev/null 2>&1 && userdel "www-$name" 2>/dev/null || true
        log_info "removed site directory and user for $name"
    else
        log_info "leaving site files in place (pass --purge-files to delete them)"
    fi

    site_log "$name" "removed (purge_db=$purge_db purge_files=$purge_files)"
}
