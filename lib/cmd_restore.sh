#!/usr/bin/env bash
# `restore-uploads` / `restore-database` — pull a backup back down.
# Destructive by design (that's the point of a restore), so both require
# --yes to actually run; without it, they show what would happen and stop.

usage_restore_uploads() {
    cat <<'EOF'
usage: provision.sh restore-uploads <name> --yes

Downloads the current backed-up state of <name>'s upload_dirs, OVERWRITING
whatever's on local disk now. Without --yes, shows what would be restored
and does nothing.
EOF
}

usage_restore_database() {
    cat <<'EOF'
usage: provision.sh restore-database <name> [--from <filename>] --yes

Restores a database dump, OVERWRITING the current database. Without
--from, restores the most recent dump. Without --yes, lists available
dumps (newest first) and does nothing.
EOF
}

# Resolves which site's data a restore actually targets: itself, for a
# normal site or an isolated-mode preview, but its PARENT for a
# shared-mode preview — that's who actually owns the shared
# database/uploads, and whose name the backups are filed under (a
# shared-mode preview is never separately backed up; there's nothing of
# its own to restore).
restore_target() {
    local name="$1"
    if is_preview "$name"; then
        read_preview_meta "$name" || { echo "$name"; return; }
        if [[ "$PREVIEW_MODE" == "shared" ]]; then
            echo "$PREVIEW_PROJECT"
            return
        fi
    fi
    echo "$name"
}

cmd_restore_uploads() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_restore_uploads; return 0; }
    load_conf
    require_root

    local name="${1:-}"
    [[ -n "$name" ]] || { usage_restore_uploads; die "site name required"; }
    shift || true

    local confirm=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes) confirm=1 ;;
            -h|--help) usage_restore_uploads; return 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done

    local target; target="$(restore_target "$name")"
    if [[ "$target" != "$name" ]]; then
        log_warn "'$name' is a shared-mode preview of '$target' — restoring '$target's actual uploads (shared by every preview of it), not something scoped to '$name' alone"
    fi

    local target_dir; target_dir="$(site_dir "$target")"
    local cfg_path; cfg_path="$(resolve_config_path "$target")"
    [[ -n "$cfg_path" ]] || die "no config for '$target' — can't tell which upload_dirs to restore"
    parse_config "$target" "$cfg_path" 0
    [[ "${#UPLOAD_DIRS[@]}" -gt 0 ]] || die "'$target' has no upload_dirs declared — nothing to restore"

    log_info "would restore for '$target': ${UPLOAD_DIRS[*]}"
    if [[ "$confirm" -ne 1 ]]; then
        log_warn "dry run — pass --yes to actually overwrite local disk with the backed-up copy"
        return 0
    fi

    if restore_site_uploads "$target" "$target_dir" "${UPLOAD_DIRS[@]}"; then
        log_info "restored uploads for '$target'"
    else
        die "restore failed for '$target'"
    fi
}

cmd_restore_database() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_restore_database; return 0; }
    load_conf
    require_root

    local name="${1:-}"
    [[ -n "$name" ]] || { usage_restore_database; die "site name required"; }
    shift || true

    local from="" confirm=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from) from="$2"; shift ;;
            --yes) confirm=1 ;;
            -h|--help) usage_restore_database; return 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done

    local target; target="$(restore_target "$name")"
    if [[ "$target" != "$name" ]]; then
        log_warn "'$name' is a shared-mode preview of '$target' — restoring '$target's actual database (shared by every preview of it), not something scoped to '$name' alone"
    fi

    # target only stays a preview itself when $name was isolated-mode
    # (restore_target redirects only for shared mode) — resolve its own
    # DB via the same path deploy-preview/remove-preview already use.
    if is_preview "$target"; then
        read_preview_meta "$target"
        resolve_preview_config "$target" "$PREVIEW_PROJECT" "$PREVIEW_MODE"
    else
        local cfg_path; cfg_path="$(resolve_config_path "$target")"
        [[ -n "$cfg_path" ]] || die "no config for '$target' — can't resolve its database"
        parse_config "$target" "$cfg_path" 0
    fi
    local db_name="$DB_NAME"

    require_rclone
    require_backup_credentials
    local remote; remote="$(backup_remote_spec)"

    if [[ -z "$from" ]]; then
        log_info "available backups for '$target' (newest first):"
        list_database_backups "$target" "$remote"
    fi

    if [[ "$confirm" -ne 1 ]]; then
        log_warn "dry run — this would restore into database '$db_name', OVERWRITING it. Pass --yes (and --from <filename> to pick one, otherwise the newest) to actually do it."
        return 0
    fi

    if restore_site_database "$target" "$db_name" "$from"; then
        log_info "restored '$db_name' for '$target'"
    else
        die "restore failed for '$target'"
    fi
}
