#!/usr/bin/env bash
# `backup-database [name]` — dump + upload each site's database. With no
# name, does every provisioned site. This is what the cron job `init`
# sets up (when DB_BACKUP_ENABLED=true) calls.

cmd_backup_database() {
    load_conf
    require_root
    [[ "$DB_BACKUP_ENABLED" == "true" ]] || die "DB_BACKUP_ENABLED is not true in provisioner.conf"

    local only="${1:-}" failures=0
    local site_path name
    for site_path in "$SITES_ROOT"/*/; do
        [[ -d "$site_path" ]] || continue
        name="$(basename "$site_path")"
        [[ -z "$only" || "$only" == "$name" ]] || continue
        is_provisioned "$name" || continue

        if is_preview "$name"; then
            read_preview_meta "$name"
            if [[ "$PREVIEW_MODE" == "shared" ]]; then
                # Shared-mode preview: its database IS $PREVIEW_PROJECT's
                # database, not a separate one of its own — dumping it here
                # would just be a redundant duplicate of the parent's own
                # backup-database run (multiplied by however many shared
                # previews the project has).
                log_info "backup-database: skipping '$name' — shared-mode preview of '$PREVIEW_PROJECT', same database"
                continue
            fi
            # Isolated mode: a real, separate database of its own —
            # resolve_preview_config handles the preview's config.yaml
            # still carrying $PREVIEW_PROJECT's name: field.
            resolve_preview_config "$name" "$PREVIEW_PROJECT" "$PREVIEW_MODE"
        else
            local cfg_path; cfg_path="$(resolve_config_path "$name")"
            [[ -n "$cfg_path" ]] || continue
            parse_config "$name" "$cfg_path" 0
        fi
        # One site's dump failing must not stop every other site from
        # being backed up this run — a bare call here would abort the
        # whole loop under set -e.
        if ! backup_site_database "$name" "$DB_NAME"; then
            log_error "backup-database failed for $name"
            failures=$((failures + 1))
        fi
    done
    [[ "$failures" -eq 0 ]] || die "$failures site(s) failed to back up"
}
