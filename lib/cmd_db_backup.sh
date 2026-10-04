#!/usr/bin/env bash
# `backup-database [name]` — dump + upload each site's database. With no
# name, does every provisioned site. This is what the cron job `init`
# sets up (when DB_BACKUP_ENABLED=true) calls.

cmd_backup_database() {
    load_conf
    require_root
    [[ "$DB_BACKUP_ENABLED" == "true" ]] || die "DB_BACKUP_ENABLED is not true in provisioner.conf"
    log_timestamps_unless_tty
    local started="$SECONDS"
    log_info "backup-database: started${1:+ ($1)}"

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
        local site_started="$SECONDS"
        BACKUP_LAST_ERROR=""
        if ! backup_site_database "$name" "$DB_NAME"; then
            log_error "backup-database failed for $name${BACKUP_LAST_ERROR:+: $BACKUP_LAST_ERROR}"
            failures=$((failures + 1))
            failed_names+=("$name")
            backup_event "$name" backup-database failed "duration_s=$((SECONDS - site_started))" "error=${BACKUP_LAST_ERROR:-backup-database failed for $name}"
        else
            ok=$((ok + 1))
            backup_event "$name" backup-database succeeded "duration_s=$((SECONDS - site_started))" "subject=${BACKUP_LAST_DUMP:-dump} ($(numfmt --to=iec --suffix=B "${BACKUP_LAST_DUMP_BYTES:-0}" 2>/dev/null || echo "${BACKUP_LAST_DUMP_BYTES:-0} bytes"))"
        fi
    done
    log_info "backup-database: done in $((SECONDS - started))s — $ok site(s) backed up, $failures failed"
    if [[ "$failures" -ne 0 ]]; then
        # One site, from `api run start`: run_notifying reports the failure.
        [[ -n "${DDEPLOY_EVENT_ATTRS:-}" ]] || notify_failure backup-database "" "${failures} site(s): ${failed_names[*]}"
        # One site: its reason is the error (what the web UI and its notification show).
        [[ "$failures" -eq 1 && -n "$only" ]] && die "${BACKUP_LAST_ERROR:-backup of ${failed_names[0]} failed}"
        die "$failures site(s) failed to back up"
    fi
}
