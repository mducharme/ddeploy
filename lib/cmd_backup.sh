#!/usr/bin/env bash
# `backup-uploads [name]` — sync upload_dirs to object storage. With no
# name, does every provisioned site that has upload_dirs declared. This
# is what the cron job `init` sets up (when BACKUP_ENABLED=true) calls.

cmd_backup_uploads() {
    load_conf
    require_root
    [[ "$BACKUP_ENABLED" == "true" ]] || die "BACKUP_ENABLED is not true in provisioner.conf"

    local only="${1:-}" failures=0
    local site_path name
    for site_path in "$SITES_ROOT"/*/; do
        [[ -d "$site_path" ]] || continue
        name="$(basename "$site_path")"
        [[ -z "$only" || "$only" == "$name" ]] || continue
        is_provisioned "$name" || continue

        local cfg_path; cfg_path="$(resolve_config_path "$name")"
        [[ -n "$cfg_path" ]] || continue
        parse_config "$name" "$cfg_path" 0
        # One site's failure (network blip, bad credentials, whatever)
        # must not stop every other site from being backed up this run —
        # a bare call here would abort the whole loop under set -e.
        if ! backup_site_uploads "$name" "${site_path%/}" "${UPLOAD_DIRS[@]}"; then
            log_error "backup-uploads failed for $name"
            failures=$((failures + 1))
        fi
    done
    [[ "$failures" -eq 0 ]] || die "$failures site(s) failed to back up"
}
