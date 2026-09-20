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
    local -a failed_names=()
    for site_path in "$SITES_ROOT"/*/; do
        [[ -d "$site_path" ]] || continue
        name="$(basename "$site_path")"
        [[ -z "$only" || "$only" == "$name" ]] || continue
        is_provisioned "$name" || continue

        if is_preview "$name"; then
            read_preview_meta "$name"
            if [[ "$PREVIEW_MODE" == "shared" ]]; then
                # Shared-mode preview: its upload_dirs are symlinks into
                # $PREVIEW_PROJECT's own directories, not real files of its
                # own — syncing it would just re-upload the parent's data
                # again under the preview's name. The parent's own
                # backup-uploads run already covers it.
                log_info "backup-uploads: skipping '$name' — shared-mode preview of '$PREVIEW_PROJECT', no uploads of its own"
                continue
            fi
            # Isolated mode: a real, separate site with its own uploads —
            # resolve_preview_config handles the preview's config.yaml
            # still carrying $PREVIEW_PROJECT's name: field.
            resolve_preview_config "$name" "$PREVIEW_PROJECT" "$PREVIEW_MODE"
        else
            local cfg_path; cfg_path="$(resolve_config_path "$name")"
            [[ -n "$cfg_path" ]] || continue
            parse_config "$name" "$cfg_path" 0
        fi
        # One site's failure (network blip, bad credentials, whatever)
        # must not stop every other site from being backed up this run —
        # a bare call here would abort the whole loop under set -e.
        if ! backup_site_uploads "$name" "$(site_dir "$name")" "${UPLOAD_DIRS[@]}"; then
            log_error "backup-uploads failed for $name"
            failures=$((failures + 1))
            failed_names+=("$name")
        fi
    done
    if [[ "$failures" -ne 0 ]]; then
        notify_failure backup-uploads "" "${failures} site(s): ${failed_names[*]}"
        die "$failures site(s) failed to back up"
    fi
}
