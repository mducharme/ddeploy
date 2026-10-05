#!/usr/bin/env bash
# `db-snapshot` / `db-import` — local safety dumps of a site's database,
# and a dump import that always takes one first, so an import (or a
# restore from a snapshot) can itself be undone. Snapshots are local
# (no object storage needed), root-only, and few: DB_SNAPSHOT_KEEP per
# site, oldest dropped first. They're a short-term undo, not a backup —
# backup-database is that.
#
#   $DDEPLOY_STATE/db-snapshots/<target>/<id>.sql.gz
#   id = <UTC timestamp>-<reason>   e.g. 20261002T143012Z-pre-import
#
# <target> is the site that owns the data: a shared-mode preview's
# parent (restore_target, lib/cmd_restore.sh).

DB_SNAPSHOTS_DIR="$DDEPLOY_STATE/db-snapshots"
DB_IMPORTS_DIR="$DDEPLOY_STATE/imports"
DB_SNAPSHOT_ID_RE='^[0-9]{8}T[0-9]{6}Z-[a-z][a-z-]{0,19}$'

usage_db_snapshot() {
    cat <<'EOF2'
usage: ddeploy db-snapshot <name> [--reason <word>]
       ddeploy db-snapshot <name> --list

Dumps <name>'s database to a local, root-only snapshot
($DDEPLOY_STATE/db-snapshots/<site>/). Keeps the newest DB_SNAPSHOT_KEEP
(default 5) per site. db-import takes one automatically before every
import. --list prints the snapshots, newest first.
EOF2
}

usage_db_import() {
    cat <<'EOF2'
usage: ddeploy db-import <name> (--from-file <path> | --snapshot <id> | --from-backup <dump>) --yes [--no-snapshot] [--keep-existing]

Replaces <name>'s database with a .sql or .sql.gz dump: takes a snapshot
of what's there now (skip with --no-snapshot) so it can be undone with
`db-import <name> --snapshot <id>`, drops every table and view, then
loads the dump. --keep-existing loads over the current tables instead of
dropping them first. Imported as the site's own DB user, like
restore-database --from-file. --from-backup takes a dump from object storage
(a filename as `ddeploy api backups <name>` lists it, in db/ or db-kept/).
EOF2
}

validate_snapshot_id() {
    [[ "$1" =~ $DB_SNAPSHOT_ID_RE ]] || die "invalid snapshot id '$1'"
}

# Sets DBX_TARGET DBX_NAME DBX_USER DBX_PASS DBX_HOST DBX_SCHEME for site
# $1 — the database a restore of $1 would write to.
db_resolve_site() {
    local name="$1"
    DBX_TARGET="$(restore_target "$name")"
    if is_preview "$DBX_TARGET"; then
        read_preview_meta "$DBX_TARGET"
        resolve_preview_config "$DBX_TARGET" "$PREVIEW_PROJECT" "$PREVIEW_MODE" >/dev/null
    else
        local cfg_path; cfg_path="$(resolve_config_path "$DBX_TARGET")"
        [[ -n "$cfg_path" ]] || die "no config for '$DBX_TARGET' — can't resolve its database"
        parse_config "$DBX_TARGET" "$cfg_path" 0 >/dev/null
    fi
    DBX_NAME="$DB_NAME"
    DBX_USER="$DB_USER"
    DBX_HOST="$DB_HOST"
    DBX_SCHEME="$DB_ENV_SCHEME"
    DBX_PASS="$(read_db_password "$DBX_TARGET" "$(site_dir "$DBX_TARGET")" "$DB_ENV_SCHEME")"
}

db_snapshot_dir() { echo "$DB_SNAPSHOTS_DIR/$1"; }

# Dumps the database of target $1 (db $2) as reason $3; prints the path.
db_snapshot_take() {
    local target="$1" db_name="$2" reason="$3"
    [[ "$reason" =~ ^[a-z][a-z-]{0,19}$ ]] || die "invalid snapshot reason '$reason'"
    local dir; dir="$(db_snapshot_dir "$target")"
    mkdir -p "$dir"
    chmod 700 "$DB_SNAPSHOTS_DIR" "$dir"
    local id; id="$(date -u +%Y%m%dT%H%M%SZ)-$reason"
    local out="$dir/$id.sql.gz" tmp="$dir/.$id.partial"
    log_info "snapshot of '$db_name' -> $out"
    ( umask 077; dump_database "$db_name" "$tmp" ) || { rm -f "$tmp"; die "snapshot of '$db_name' failed — nothing was changed"; }
    mv "$tmp" "$out"
    db_snapshot_prune "$target"
    printf '%s\n' "$out"
}

db_snapshot_prune() {
    local dir; dir="$(db_snapshot_dir "$1")"
    local keep="${DB_SNAPSHOT_KEEP:-5}"
    [[ "$keep" =~ ^[1-9][0-9]?$ ]] || keep=5
    local -a all=()
    mapfile -t all < <(find "$dir" -maxdepth 1 -name '*.sql.gz' -printf '%f\n' 2>/dev/null | sort -r)
    local i
    for (( i = keep; i < ${#all[@]}; i++ )); do rm -f "$dir/${all[i]}"; done
}

# Snapshots of target $1, newest first: id<TAB>bytes<TAB>reason per line.
db_snapshot_list() {
    local dir f id
    dir="$(db_snapshot_dir "$1")"
    [[ -d "$dir" ]] || return 0
    while IFS= read -r f; do
        id="${f%.sql.gz}"
        [[ "$id" =~ $DB_SNAPSHOT_ID_RE ]] || continue
        printf '%s\t%s\t%s\n' "$id" "$(stat -c %s "$dir/$f")" "${id#*Z-}"
    done < <(find "$dir" -maxdepth 1 -name '*.sql.gz' -printf '%f\n' | sort -r)
}

# Drops every table and view in db $1 (as its own user $2/$3): an import
# replaces the database rather than layering over it — otherwise tables
# that aren't in the dump (created by a migration since, say) survive,
# and restoring a snapshot wouldn't really put things back.
db_empty_database() {
    local db_name="$1" user="$2" pass="$3" host="$4"
    local objects sql="SET FOREIGN_KEY_CHECKS=0;" name type
    objects="$(mysql_as_user "$user" "$pass" -h "$host" -N -B "$db_name" -e \
        "SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = DATABASE()")" \
        || die "couldn't list the tables of '$db_name'"
    while IFS=$'\t' read -r name type; do
        [[ -n "$name" ]] || continue
        name="${name//\`/\`\`}"
        if [[ "$type" == VIEW ]]; then sql+="DROP VIEW IF EXISTS \`$name\`;"; else sql+="DROP TABLE IF EXISTS \`$name\`;"; fi
    done <<< "$objects"
    mysql_as_user "$user" "$pass" -h "$host" "$db_name" -e "$sql" || die "couldn't empty '$db_name' before the import"
}

cmd_db_snapshot() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_db_snapshot; return 0; }
    load_conf
    require_root
    local name="${1:-}" list=0 reason=manual
    [[ -n "$name" ]] || { usage_db_snapshot; die "site name required"; }
    shift
    validate_name "$name"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list) list=1 ;;
            --reason) reason="${2:-}"; shift ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done
    is_provisioned "$name" || die "'$name' is not provisioned"
    db_resolve_site "$name"
    if [[ "$list" -eq 1 ]]; then
        db_snapshot_list "$DBX_TARGET"
        return 0
    fi
    event_attr kind db-snapshot
    local out; out="$(db_snapshot_take "$DBX_TARGET" "$DBX_NAME" "$reason")"
    event_attr subject "snapshot $(basename "$out" .sql.gz)"
    site_log "$name" "db-snapshot: $(basename "$out") ($(notify_trigger))" ok
}

cmd_db_import() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_db_import; return 0; }
    load_conf
    require_root
    local name="${1:-}" from_file="" snapshot_id="" from_backup="" confirm=0 take_snapshot=1 delete_file=0 keep_existing=0
    [[ -n "$name" ]] || { usage_db_import; die "site name required"; }
    shift
    validate_name "$name"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from-file) from_file="${2:-}"; shift ;;
            --snapshot) snapshot_id="${2:-}"; shift ;;
            --from-backup) from_backup="${2:-}"; shift ;;
            --yes) confirm=1 ;;
            --no-snapshot) take_snapshot=0 ;;
            --keep-existing) keep_existing=1 ;;
            # Internal (api run start db-import): the upload spool file is
            # removed once loaded. Only ever honored inside DB_IMPORTS_DIR.
            --delete-file) delete_file=1 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done
    local sources=0
    [[ -n "$from_file" ]] && sources=$((sources + 1))
    [[ -n "$snapshot_id" ]] && sources=$((sources + 1))
    [[ -n "$from_backup" ]] && sources=$((sources + 1))
    [[ "$sources" -eq 1 ]] || die "give exactly one of --from-file <path>, --snapshot <id>, --from-backup <dump>"
    is_provisioned "$name" || die "'$name' is not provisioned"
    db_resolve_site "$name"
    [[ -n "$DBX_PASS" ]] || die "no existing DB credentials found for '$DBX_TARGET' — provision it first"
    [[ "$DBX_TARGET" == "$name" ]] || log_warn "'$name' is a shared-mode preview of '$DBX_TARGET' — importing into '$DBX_TARGET's database, which every preview of it shares"

    local label
    if [[ -n "$from_backup" ]]; then
        validate_backup_dump_name "$from_backup"
        require_rclone
        require_backup_credentials
        local remote; remote="$(backup_remote_spec)"
        local prefix; prefix="$(backup_dump_prefix "$remote" "$DBX_TARGET" "$from_backup")" \
            || die "no backup '$from_backup' for '$DBX_TARGET' in $BACKUP_BUCKET"
        local dl; dl="$(mktemp -d)"
        # shellcheck disable=SC2064  # expand now
        trap "rm -rf '$dl'" EXIT
        log_info "downloading $prefix/$from_backup from $BACKUP_BUCKET"
        rclone copy "${remote}/$DBX_TARGET/$prefix/$from_backup" "$dl/" || die "download of $from_backup failed — nothing was changed"
        from_file="$dl/$from_backup"
        label="backup $from_backup"
        event_attr kind db-restore
    elif [[ -n "$snapshot_id" ]]; then
        validate_snapshot_id "$snapshot_id"
        from_file="$(db_snapshot_dir "$DBX_TARGET")/$snapshot_id.sql.gz"
        [[ -f "$from_file" ]] || die "no snapshot '$snapshot_id' for '$DBX_TARGET'"
        label="snapshot $snapshot_id"
        event_attr kind db-restore
    else
        [[ -f "$from_file" ]] || die "file not found: $from_file"
        label="$(basename "$from_file")"
        event_attr kind db-import
    fi
    local bytes; bytes="$(stat -c %s "$from_file")"
    # A web upload's spool file goes when this run is over, imported or not.
    if [[ "$delete_file" -eq 1 && -z "$snapshot_id" ]]; then
        local spool; spool="$(readlink -f "$from_file")"
        # shellcheck disable=SC2064  # expand now
        [[ "$spool" == "$DB_IMPORTS_DIR"/* ]] && trap "rm -f '$spool'" EXIT
    fi
    if [[ "$confirm" -ne 1 ]]; then
        log_warn "dry run — this would load $label ($bytes bytes) into '$DBX_NAME', OVERWRITING it. Pass --yes."
        return 0
    fi

    local undo=""
    if [[ "$take_snapshot" -eq 1 ]]; then
        undo="$(basename "$(db_snapshot_take "$DBX_TARGET" "$DBX_NAME" pre-import)" .sql.gz)"
        log_info "to undo this import: ddeploy db-import $name --snapshot $undo --yes"
    fi
    if [[ "$keep_existing" -eq 0 ]]; then
        log_info "emptying '$DBX_NAME' (every table and view) before loading"
        db_empty_database "$DBX_NAME" "$DBX_USER" "$DBX_PASS" "$DBX_HOST"
    fi
    log_info "loading $label ($bytes bytes) into '$DBX_NAME' as '$DBX_USER'"
    if ! load_sql_dump_into_db "$from_file" "$DBX_NAME" "$DBX_USER" "$DBX_PASS"; then
        die "import into '$DBX_NAME' failed${undo:+ — the database may be partly loaded; restore it with: ddeploy db-import $name --snapshot $undo --yes}"
    fi
    event_attr subject "$label${undo:+ (undo: $undo)}"
    site_log "$name" "db-import: loaded $label into '$DBX_NAME' ($(notify_trigger))${undo:+ — undo snapshot $undo}" ok
    log_info "imported $label into '$DBX_NAME'"

}

# A dump filename as backup_site_database writes them (<db>-YYYYMMDD-HHMMSS.sql.gz),
# or anything else safe someone put in db-kept/ by hand.
validate_backup_dump_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,200}\.sql(\.gz)?$ ]] || die "invalid backup name '$1'"
}

# Prints db or db-kept: where dump $3 of site $2 lives; fails if neither.
backup_dump_prefix() {
    local remote="$1" site="$2" file="$3" p
    for p in db db-kept; do
        if rclone lsf "${remote}/$site/$p/" 2>/dev/null | grep -qxF "$file"; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}
