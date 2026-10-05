#!/usr/bin/env bash
# `uploads-import` / `uploads-snapshot` — put files into a site's upload
# directories (the persistent ones every release links to), from an
# archive, with a snapshot first so it can be undone.
#
#   $PERSISTENT_ROOT/<target>/<upload_dir>/            the live files
#   $PERSISTENT_ROOT/<target>/.uploads-snapshots/<id>/ root-only, never linked
#       dir    the upload_dir it's a copy of
#       tree/  the copy: hardlinks (merge, manual) or the old folder itself (replace)
#
# Hardlink snapshots cost no space until files change, and an import never
# writes into an existing file: it removes and recreates it (cp
# --remove-destination), so the snapshot keeps the old content. <target>
# is the site that owns the files: a shared-mode preview's parent
# (restore_target, lib/cmd_restore.sh).
#
# Extraction is lib/uploads_extract.py, run as the site's own user into a
# staging folder, after checking every archive member (see its header).

UPLOADS_SNAPSHOT_ID_RE='^[0-9]{8}T[0-9]{6}Z-[a-z0-9-]{1,40}$'

usage_uploads_import() {
    cat <<'EOF2'
usage: ddeploy uploads-import <name> --dir <upload_dir> --from-file <archive> --yes [--mode merge|replace] [--strip auto|yes|no]
       ddeploy uploads-import <name> --dir <upload_dir> --from-ssh <user@host:path> [--ssh-port <n>] --yes [--mode merge|replace]
       ddeploy uploads-import <name> --dir <upload_dir> --from-backup --yes [--version <run>]
       ddeploy uploads-import <name> --snapshot <id> --yes

Unpacks a .zip, .tar or .tar.gz into one of <name>'s upload_dirs (as
declared in its config; `uploads-snapshot <name> --list` shows them).

  --mode merge     (default) add the archive's files, overwriting any with
                   the same path; everything else stays
  --mode replace   the folder becomes exactly the archive's contents
  --strip auto     (default) if everything is inside one folder named like
                   the upload dir (someone zipped the folder itself), unwrap it

--from-ssh copies a folder from another server with rsync over SSH, using
this server's fetch key (`fetch-key` shows it, and the authorized_keys line
to add over there). The host's key must have been confirmed first (the web
UI's "Test connection", or ssh-keyscan into /etc/ddeploy/fetch-known-hosts).
With an rrsync-bound key, leave the path empty: user@host:

--from-backup restores the folder from its object-storage backup: the
mirror (replaces the folder), or with --version <run> the files that
backup run overwrote or deleted (merged back in) — see
UPLOADS_BACKUP_VERSIONS_DAYS.

Either way a snapshot is taken first; undo with --snapshot <id> (printed at
the end). Only plain files and folders are accepted — no links, no absolute
or '..' paths — and the archive is unpacked as the site's own user.
EOF2
}

usage_uploads_snapshot() {
    cat <<'EOF2'
usage: ddeploy uploads-snapshot <name> [--dir <upload_dir>]
       ddeploy uploads-snapshot <name> --list

Takes a hardlink snapshot of <name>'s upload dirs (or just one) — instant,
and no extra disk space until files change. Keeps the newest
UPLOADS_SNAPSHOT_KEEP (default 3) per site. --list shows the upload dirs and
the snapshots.
EOF2
}

validate_uploads_snapshot_id() {
    [[ "$1" =~ $UPLOADS_SNAPSHOT_ID_RE ]] || die "invalid uploads snapshot id '$1'"
}

# Sets UPX_TARGET UPX_OWNER UPLOAD_DIRS[] for site $1.
uploads_resolve_site() {
    local name="$1"
    UPX_TARGET="$(restore_target "$name")"
    if is_preview "$UPX_TARGET"; then
        read_preview_meta "$UPX_TARGET"
        resolve_preview_config "$UPX_TARGET" "$PREVIEW_PROJECT" "$PREVIEW_MODE" >/dev/null
    else
        local cfg_path; cfg_path="$(resolve_config_path "$UPX_TARGET")"
        [[ -n "$cfg_path" ]] || die "no config for '$UPX_TARGET' — can't resolve its upload_dirs"
        parse_config "$UPX_TARGET" "$cfg_path" 0 >/dev/null
    fi
    UPX_OWNER="www-$UPX_TARGET"
    id -u "$UPX_OWNER" >/dev/null 2>&1 || die "no Linux user $UPX_OWNER for '$UPX_TARGET'"
}

# $1 upload dir — dies unless it's one of the resolved UPLOAD_DIRS.
uploads_require_dir() {
    local want="$1" d
    for d in "${UPLOAD_DIRS[@]}"; do [[ "$d" == "$want" ]] && return 0; done
    die "'$want' isn't one of ${UPX_TARGET}'s upload_dirs (${UPLOAD_DIRS[*]:-none declared})"
}

uploads_path() { echo "$PERSISTENT_ROOT/$UPX_TARGET/$1"; }
uploads_snapshots_root() { echo "$PERSISTENT_ROOT/$UPX_TARGET/.uploads-snapshots"; }

# Snapshots dir $1 (an upload dir) as reason $2; $3 "link" (hardlink copy,
# the folder stays) or "move" (the folder itself becomes the snapshot).
# Prints the id, or nothing when there was nothing to snapshot.
uploads_snapshot_take() {
    local dir="$1" reason="$2" how="$3"
    local live; live="$(uploads_path "$dir")"
    [[ -d "$live" ]] || return 0
    [[ -n "$(find "$live" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || return 0
    local root; root="$(uploads_snapshots_root)"
    local slug; slug="$(printf '%s' "$dir" | tr '/A-Z' '-a-z' | tr -cd 'a-z0-9-' | cut -c1-24)"
    local id; id="$(date -u +%Y%m%dT%H%M%SZ)-$reason-${slug:-dir}"
    local snap="$root/$id"
    install -d -m 700 -o root -g root "$root" "$snap"
    printf '%s\n' "$dir" > "$snap/dir"
    printf '%s\n' "$reason" > "$snap/reason"
    if [[ "$how" == move ]]; then
        mv "$live" "$snap/tree"
    else
        cp -al "$live" "$snap/tree" || { rm -rf "$snap"; die "couldn't snapshot '$live'"; }
    fi
    uploads_snapshot_prune
    printf '%s' "$id"
}

uploads_snapshot_prune() {
    local root; root="$(uploads_snapshots_root)"
    local keep="${UPLOADS_SNAPSHOT_KEEP:-3}"
    [[ "$keep" =~ ^[1-9][0-9]?$ ]] || keep=3
    local -a all=()
    mapfile -t all < <(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r)
    local i
    for (( i = keep; i < ${#all[@]}; i++ )); do rm -rf "${root:?}/${all[i]}"; done
}

# id<TAB>dir<TAB>reason per snapshot, newest first.
uploads_snapshot_list() {
    local root id
    root="$(uploads_snapshots_root)"
    [[ -d "$root" ]] || return 0
    while IFS= read -r id; do
        [[ "$id" =~ $UPLOADS_SNAPSHOT_ID_RE && -f "$root/$id/dir" ]] || continue
        printf '%s\t%s\t%s\n' "$id" "$(head -n 1 "$root/$id/dir")" "$(head -n 1 "$root/$id/reason" 2>/dev/null || echo snapshot)"
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
}

cmd_uploads_snapshot() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_uploads_snapshot; return 0; }
    load_conf
    require_root
    local name="${1:-}" list=0 only=""
    [[ -n "$name" ]] || { usage_uploads_snapshot; die "site name required"; }
    shift
    validate_name "$name"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list) list=1 ;;
            --dir) only="${2:-}"; shift ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done
    is_provisioned "$name" || die "'$name' is not provisioned"
    uploads_resolve_site "$name"
    if [[ "$list" -eq 1 ]]; then
        local d
        for d in "${UPLOAD_DIRS[@]}"; do printf 'dir\t%s\t%s\n' "$d" "$(uploads_path "$d")"; done
        uploads_snapshot_list | sed 's/^/snapshot\t/'
        return 0
    fi
    [[ -z "$only" ]] || uploads_require_dir "$only"
    local d id taken=""
    for d in "${UPLOAD_DIRS[@]}"; do
        [[ -z "$only" || "$d" == "$only" ]] || continue
        id="$(uploads_snapshot_take "$d" manual link)"
        [[ -n "$id" ]] && { log_info "snapshot of '$d': $id"; taken+="${taken:+, }$id"; }
    done
    [[ -n "$taken" ]] || log_info "nothing to snapshot (the upload dirs are empty)"
    event_attr kind uploads-snapshot
    event_attr subject "${taken:-nothing to snapshot}"
}

# Checks and unpacks archive $1 into staging folder $2 as the site's user
# (lib/uploads_extract.py): at most $3 bytes, --strip $4, target dir $5.
# Sets UNPACKED_FILES/BYTES/SKIPPED/STRIPPED; dies, changing nothing, on a
# refused archive.
uploads_unpack() {
    local archive="$1" staging="$2" max="$3" strip="$4" dir="$5"
    local summary errf rc=0
    errf="$(mktemp)"
    summary="$(sudo -u "$UPX_OWNER" -- python3 "$PROVISIONER_DIR/lib/uploads_extract.py" "$staging" \
        --max-bytes "$max" --strip "$strip" --expect-top "$(basename "$dir")" \
        < "$archive" 2>"$errf")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        local why; why="$(sed 's/^refused: //' "$errf" | tail -n 1)"
        rm -f "$errf"
        die "${why:-unpacking failed (exit $rc)} — nothing was changed"
    fi
    rm -f "$errf"
    UNPACKED_FILES="$(sed -E 's/.*"files": ([0-9]+).*/\1/' <<< "$summary")"
    UNPACKED_BYTES="$(sed -E 's/.*"bytes": ([0-9]+).*/\1/' <<< "$summary")"
    UNPACKED_SKIPPED="$(sed -E 's/.*"skipped": ([0-9]+).*/\1/' <<< "$summary")"
    UNPACKED_STRIPPED="$(sed -E 's/.*"stripped": "([^"]*)".*/\1/' <<< "$summary")"
}

cmd_uploads_import() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_uploads_import; return 0; }
    load_conf
    require_root
    local name="${1:-}" dir="" from_file="" snapshot="" mode=merge strip=auto confirm=0 delete_file=0 from_backup=0 version="" from_ssh="" ssh_port=22
    [[ -n "$name" ]] || { usage_uploads_import; die "site name required"; }
    shift
    validate_name "$name"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir) dir="${2:-}"; shift ;;
            --from-file) from_file="${2:-}"; shift ;;
            --snapshot) snapshot="${2:-}"; shift ;;
            --from-backup) from_backup=1 ;;
            --from-ssh) from_ssh="${2:-}"; shift ;;
            --ssh-port) ssh_port="${2:-}"; shift ;;
            --version) version="${2:-}"; shift ;;
            --mode) mode="${2:-}"; shift ;;
            --strip) strip="${2:-}"; shift ;;
            --yes) confirm=1 ;;
            # Internal (api run start uploads-import): the upload spool
            # file is removed afterwards. Only honored inside DB_IMPORTS_DIR.
            --delete-file) delete_file=1 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done
    [[ "$mode" == merge || "$mode" == replace ]] || die "--mode is merge or replace"
    [[ "$strip" == auto || "$strip" == yes || "$strip" == no ]] || die "--strip is auto, yes or no"
    local sources=0
    [[ -n "$from_file" ]] && sources=$((sources + 1))
    [[ -n "$snapshot" ]] && sources=$((sources + 1))
    [[ "$from_backup" -eq 1 ]] && sources=$((sources + 1))
    [[ -n "$from_ssh" ]] && sources=$((sources + 1))
    [[ "$sources" -eq 1 ]] || die "give exactly one of --from-file <archive>, --snapshot <id>, --from-backup, --from-ssh <user@host:path>"
    [[ -z "$from_ssh" ]] || fetch_parse_source "$from_ssh" "$ssh_port"
    [[ -z "$version" || "$from_backup" -eq 1 ]] || die "--version goes with --from-backup"
    [[ -z "$version" || "$version" =~ $UPLOADS_VERSION_ID_RE ]] || die "invalid backup version '$version'"
    is_provisioned "$name" || die "'$name' is not provisioned"
    uploads_resolve_site "$name"
    [[ "$UPX_TARGET" == "$name" ]] || log_warn "'$name' is a shared-mode preview of '$UPX_TARGET' — these are '$UPX_TARGET's own upload folders"

    if [[ -n "$snapshot" ]]; then
        validate_uploads_snapshot_id "$snapshot"
        local snap; snap="$(uploads_snapshots_root)/$snapshot"
        [[ -d "$snap/tree" && -f "$snap/dir" ]] || die "no uploads snapshot '$snapshot' for '$UPX_TARGET'"
        dir="$(head -n 1 "$snap/dir")"
        uploads_require_dir "$dir"
        [[ "$confirm" -eq 1 ]] || { log_warn "dry run — this would put '$dir' back as it was in $snapshot. Pass --yes."; return 0; }
        event_attr kind uploads-restore
        local undo; undo="$(uploads_snapshot_take "$dir" pre-restore move)"
        local live; live="$(uploads_path "$dir")"
        rm -rf "$live"
        cp -al "$snap/tree" "$live"
        log_info "'$dir' restored from $snapshot${undo:+ (undo: uploads-import $name --snapshot $undo --yes)}"
        event_attr subject "$dir from $snapshot${undo:+ (undo: $undo)}"
        site_log "$name" "uploads-restore: $dir from $snapshot ($(notify_trigger))" ok
        return 0
    fi

    [[ -n "$dir" ]] || die "--dir <upload_dir> required (one of: ${UPLOAD_DIRS[*]:-none declared})"
    uploads_require_dir "$dir"
    local source_desc
    if [[ "$from_backup" -eq 1 ]]; then
        # The mirror is the folder's backed-up state: it replaces the
        # folder. A version holds only the files that run overwrote or
        # deleted: they're merged back in.
        if [[ -n "$version" ]]; then mode=merge; source_desc="backup version $version"; else mode=replace; source_desc="backup mirror"; fi
        [[ "$confirm" -eq 1 ]] || { log_warn "dry run — this would restore '$dir' from its $source_desc ($mode). Pass --yes."; return 0; }
        event_attr kind uploads-restore
    elif [[ -n "$from_ssh" ]]; then
        source_desc="$from_ssh"
        [[ "$ssh_port" == 22 ]] || source_desc+=" (port $ssh_port)"
        [[ -f "$FETCH_KEY" ]] || die "no fetch key yet — run 'ddeploy fetch-key' and add it on $FETCH_SRC_HOST"
        command -v rsync >/dev/null 2>&1 || die "rsync isn't installed — re-run 'init'"
        [[ "$confirm" -eq 1 ]] || { log_warn "dry run — this would copy $source_desc into '$dir' ($mode). Pass --yes."; return 0; }
        event_attr kind uploads-fetch
    else
        [[ -f "$from_file" ]] || die "file not found: $from_file"
        source_desc="$(basename "$from_file")"
        [[ "$confirm" -eq 1 ]] || { log_warn "dry run — this would unpack $source_desc into '$dir' ($mode). Pass --yes."; return 0; }
        event_attr kind uploads-import
    fi

    local live; live="$(uploads_path "$dir")"
    local base="$PERSISTENT_ROOT/$UPX_TARGET"
    mkdir -p "$base"
    # Disk: the unpacked size may not exceed what's free, less a reserve
    # (the extractor checks declared sizes against this before writing).
    local avail; avail="$(df --output=avail -B1 "$base" | tail -n 1 | tr -d ' ')"
    local reserve=$(( 1024 * 1024 * 1024 ))
    (( avail > reserve )) || die "not enough free disk space on $(df --output=target "$base" | tail -n 1)"
    local staging="$base/.uploads-staging-${DDEPLOY_RUN_ID:-$(date +%s)}"
    rm -rf "$staging"
    if [[ -n "$from_ssh" ]]; then
        # rsync runs as root: root-only until it's done, so the site user
        # can't plant links in it meanwhile. Handed over below.
        install -d -m 700 -o root -g root "$staging"
    else
        install -d -m 750 -o "$UPX_OWNER" -g www-data "$staging"
    fi
    # The spool file goes either way once this run is over: a refused
    # archive isn't worth keeping (it's not retried), an imported one is
    # done. Only ever inside DB_IMPORTS_DIR.
    local spool_rm=""
    if [[ "$delete_file" -eq 1 ]]; then
        local real; real="$(readlink -f "$from_file")"
        [[ "$real" == "$DB_IMPORTS_DIR"/* ]] && spool_rm="$real"
    fi
    # shellcheck disable=SC2064  # paths are ours, expand them now
    trap "rm -rf '$staging' ${spool_rm:+'$spool_rm'}" EXIT

    local files bytes skipped=0 stripped=""
    if [[ "$from_backup" -eq 1 ]]; then
        require_rclone
        require_backup_credentials
        local remote; remote="$(backup_remote_spec)"
        local src="${remote}/$UPX_TARGET/$dir"
        [[ -n "$version" ]] && src="${remote}/$UPX_TARGET/.versions/$version/$dir"
        local size_json
        size_json="$(timeout 120 rclone size --json "$src" 2>/dev/null || true)"
        files="$(sed -nE 's/.*"count": ?([0-9]+).*/\1/p' <<< "$size_json")"
        bytes="$(sed -nE 's/.*"bytes": ?([0-9]+).*/\1/p' <<< "$size_json")"
        [[ -n "$files" && "$files" != 0 ]] || die "nothing in the $source_desc of '$dir' — nothing was changed"
        (( bytes < avail - reserve )) || die "the $source_desc of '$dir' is $bytes bytes, more than the free disk space — nothing was changed"
        log_info "downloading the $source_desc of '$dir' ($files file(s), $bytes bytes)"
        # Into the empty staging folder: fresh files, never written over
        # live ones (which hardlink snapshots share).
        rclone copy "$src" "$staging" || die "download from $BACKUP_BUCKET failed — nothing was changed"
    elif [[ -n "$from_ssh" ]]; then
        log_info "listing $source_desc"
        fetch_dry_run "$FETCH_SRC_USER" "$FETCH_SRC_HOST" "$ssh_port" "$FETCH_SRC_PATH" || die "$FETCH_ERROR — nothing was changed"
        files="$FETCH_FILES" bytes="$FETCH_BYTES"
        [[ "$files" != 0 ]] || die "no files in $source_desc — nothing was changed"
        (( bytes < avail - reserve )) || die "$source_desc is $bytes bytes, more than the free disk space — nothing was changed"
        log_info "copying $files file(s), $bytes bytes from $FETCH_SRC_HOST"
        fetch_copy "$FETCH_SRC_USER" "$FETCH_SRC_HOST" "$ssh_port" "$FETCH_SRC_PATH" "$staging"
    else
        log_info "checking and unpacking $source_desc ($(stat -c %s "$from_file") bytes) as $UPX_OWNER"
        uploads_unpack "$from_file" "$staging" "$(( avail - reserve ))" "$strip" "$dir"
        files="$UNPACKED_FILES" bytes="$UNPACKED_BYTES" skipped="$UNPACKED_SKIPPED" stripped="$UNPACKED_STRIPPED"
    fi
    local note=""
    [[ -n "$stripped" ]] && note+=" (unwrapped the '$stripped' folder)"
    [[ "$skipped" != 0 ]] && note+=", skipped $skipped junk file(s) (__MACOSX, .DS_Store...)"
    log_info "$([[ "$from_backup" -eq 1 || -n "$from_ssh" ]] && echo copied || echo unpacked) $files file(s), $bytes bytes$note"
    chown -R "$UPX_OWNER:www-data" "$staging"
    # setgid on folders, like the persistent store's own: files PHP writes
    # into them later keep the www-data group nginx reads through.
    find "$staging" -type d -exec chmod 2750 {} +

    local undo=""
    if [[ "$mode" == replace ]]; then
        undo="$(uploads_snapshot_take "$dir" pre-import move)"
        rm -rf "$live"
        mkdir -p "$(dirname "$live")"
        mv "$staging" "$live"
    else
        undo="$(uploads_snapshot_take "$dir" pre-import link)"
        if [[ ! -d "$live" ]]; then
            install -d -m 2750 -o "$UPX_OWNER" -g www-data "$live"
        fi
        # Hardlink staging into place (no second copy of the data); every
        # existing file with the same path is removed and recreated, never
        # written into, so the snapshot keeps its old content.
        cp -al --remove-destination "$staging/." "$live/"
    fi
    rm -rf "$staging" ${spool_rm:+"$spool_rm"}
    trap - EXIT
    log_info "'$dir': $mode done${undo:+ — undo with: ddeploy uploads-import $name --snapshot $undo --yes}"
    event_attr subject "$files file(s) into $dir from $source_desc ($mode)${undo:+ (undo: $undo)}"
    site_log "$name" "uploads-import: $files file(s), $bytes bytes into $dir from $source_desc ($mode, $(notify_trigger))${undo:+ — undo snapshot $undo}" ok

}
