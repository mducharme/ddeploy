#!/usr/bin/env bash
# `backup-uploads [name]` — sync upload_dirs to object storage. With no
# name, does every provisioned site that has upload_dirs declared. This
# is what the cron job `init` sets up (when BACKUP_ENABLED=true) calls.

cmd_backup_uploads() {
    load_conf
    require_root
    [[ "$BACKUP_ENABLED" == "true" ]] || die "BACKUP_ENABLED is not true in provisioner.conf"
    log_timestamps_unless_tty
    local started="$SECONDS"
    log_info "backup-uploads: started${1:+ ($1)}"
    # One version folder per run, shared by every site's sync.
    BACKUP_RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"

    local only="${1:-}" failures=0 ok=0
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
        local site_started="$SECONDS"
        BACKUP_LAST_ERROR=""
        if ! backup_site_uploads "$name" "$(site_dir "$name")" "${UPLOAD_DIRS[@]}"; then
            log_error "backup-uploads failed for $name${BACKUP_LAST_ERROR:+: $BACKUP_LAST_ERROR}"
            failures=$((failures + 1))
            failed_names+=("$name")
            backup_event "$name" backup-uploads failed "duration_s=$((SECONDS - site_started))" "error=${BACKUP_LAST_ERROR:-backup-uploads failed for $name}"
        else
            ok=$((ok + 1))
            backup_event "$name" backup-uploads succeeded "duration_s=$((SECONDS - site_started))" "subject=${UPLOAD_DIRS[*]} synced"
        fi
    done
    log_info "backup-uploads: done in $((SECONDS - started))s — $ok site(s) backed up, $failures failed"
    if [[ "$failures" -ne 0 ]]; then
        # One site, from `api run start`: run_notifying reports the failure.
        [[ -n "${DDEPLOY_EVENT_ATTRS:-}" ]] || notify_failure backup-uploads "" "${failures} site(s): ${failed_names[*]}"
        # One site: its reason is the error (what the web UI and its notification show).
        [[ "$failures" -eq 1 && -n "$only" ]] && die "${BACKUP_LAST_ERROR:-backup of ${failed_names[0]} failed}"
        die "$failures site(s) failed to back up"
    fi
}
