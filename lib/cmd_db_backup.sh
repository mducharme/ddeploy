#!/usr/bin/env bash
# `backup-database [name]` — dump + upload each site's database. With no
# name, does every provisioned site. This is what the cron job `init`
# sets up (when DB_BACKUP_ENABLED=true) calls.

cmd_backup_database() {
    load_conf
    require_root
    [[ "$DB_BACKUP_ENABLED" == "true" ]] || die "DB_BACKUP_ENABLED is not true in provisioner.conf"

    local only="${1:-}"
    local site_path name
    for site_path in "$SITES_ROOT"/*/; do
        [[ -d "$site_path" ]] || continue
        name="$(basename "$site_path")"
        [[ -z "$only" || "$only" == "$name" ]] || continue
        is_provisioned "$name" || continue

        local cfg_path; cfg_path="$(resolve_config_path "$name")"
        [[ -n "$cfg_path" ]] || continue
        parse_config "$name" "$cfg_path" 0
        backup_site_database "$name" "$DB_NAME"
    done
}
