#!/usr/bin/env bash
# Backs up each site's own database as a compressed mysqldump, uploaded
# to object storage — same BACKUP_CREDENTIALS/BACKUP_BUCKET as uploads
# backup (lib/backup.sh), different prefix. Unlike uploads, a running
# database's data files aren't safe to sync directly (a copy taken
# mid-write is a corrupted, unrestorable backup) — a logical dump is the
# consistent, restorable unit here instead, so this produces a dated
# series of dumps rather than a live mirror, and prunes old ones after
# DB_BACKUP_RETENTION_DAYS.

# Dumps $1 (db name) to $2 (output path, gzipped), using the same
# local-vs-remote connection logic as db_admin_mysql (lib/db.sh) — works
# whether the database is co-located or on a dedicated init-db server.
# Relies on provision.sh's global `set -o pipefail` for the `| gzip` here
# to still surface a failing mysqldump's exit status, not gzip's.
dump_database() {
    local db_name="$1" out="$2"
    if [[ ( "$DB_HOST" == "127.0.0.1" || "$DB_HOST" == "localhost" ) && -z "$DB_ADMIN_CREDENTIALS" ]]; then
        mysqldump --single-transaction --routines --triggers --events "$db_name" | gzip > "$out"
    else
        [[ -n "$DB_ADMIN_CREDENTIALS" ]] || die "DB_HOST ($DB_HOST) is remote but DB_ADMIN_CREDENTIALS is not set"
        [[ -f "$DB_ADMIN_CREDENTIALS" ]] || die "DB_ADMIN_CREDENTIALS file not found: $DB_ADMIN_CREDENTIALS"
        mysqldump --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" \
            --single-transaction --routines --triggers --events "$db_name" | gzip > "$out"
    fi
}

# $1 site name, $2 db name
backup_site_database() {
    local name="$1" db_name="$2"
    require_rclone
    require_backup_credentials
    local remote; remote="$(backup_remote_spec)"

    local tmp_dir ts dump
    tmp_dir="$(mktemp -d)"
    ts="$(date -u +%Y%m%d-%H%M%S)"
    dump="$tmp_dir/${db_name}-${ts}.sql.gz"

    log_info "backup: $name: dumping database '$db_name'"
    if ! dump_database "$db_name" "$dump"; then
        log_warn "backup: $name: mysqldump failed, skipping upload"
        rm -rf "$tmp_dir"
        return 1
    fi

    log_info "backup: $name: uploading $(basename "$dump") -> $BACKUP_BUCKET/$name/db/"
    local uploaded=1
    rclone copy "$dump" "${remote}/$name/db/" || uploaded=0
    rm -rf "$tmp_dir"
    if [[ "$uploaded" -eq 0 ]]; then
        log_warn "backup: $name: upload failed"
        return 1
    fi

    prune_database_backups "$name" "$remote"
}

# Deletes dumps older than DB_BACKUP_RETENTION_DAYS from object storage.
prune_database_backups() {
    local name="$1" remote="$2"
    local days="${DB_BACKUP_RETENTION_DAYS:-7}"
    rclone delete "${remote}/$name/db/" --min-age "${days}d" 2>/dev/null || true
}

# Lists $1's available dump filenames, newest first — filenames encode a
# zero-padded timestamp (<db>-YYYYMMDD-HHMMSS.sql.gz), so a plain
# lexicographic sort is also a chronological one.
list_database_backups() {
    local name="$1" remote="$2"
    rclone lsf "${remote}/$name/db/" 2>/dev/null | sort -r
}

# Downloads $3 (a filename from list_database_backups, or empty for the
# newest available) and restores it into $2, OVERWRITING that database.
# $1 name (the bucket prefix backups are filed under — not necessarily
# $2's own name, see restore_target in lib/cmd_restore.sh for why a
# shared-mode preview's restore targets its parent's prefix).
restore_site_database() {
    local name="$1" db_name="$2" filename="$3"
    require_rclone
    require_backup_credentials
    local remote; remote="$(backup_remote_spec)"

    if [[ -z "$filename" ]]; then
        filename="$(list_database_backups "$name" "$remote" | head -n1)"
        [[ -n "$filename" ]] || { log_error "restore: no backups found for '$name'"; return 1; }
    fi

    local tmp_dir; tmp_dir="$(mktemp -d)"
    log_info "restore: $name: downloading $filename"
    if ! rclone copy "${remote}/$name/db/$filename" "$tmp_dir/"; then
        log_error "restore: $name: failed to download $filename"
        rm -rf "$tmp_dir"
        return 1
    fi

    log_info "restore: $name: restoring '$filename' into database '$db_name' (OVERWRITING it)"
    local ok=1
    if [[ ( "$DB_HOST" == "127.0.0.1" || "$DB_HOST" == "localhost" ) && -z "$DB_ADMIN_CREDENTIALS" ]]; then
        gunzip -c "$tmp_dir/$filename" | mysql "$db_name" || ok=0
    else
        gunzip -c "$tmp_dir/$filename" | mysql --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" "$db_name" || ok=0
    fi
    rm -rf "$tmp_dir"
    [[ "$ok" -eq 1 ]]
}
