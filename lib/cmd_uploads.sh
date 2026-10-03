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
       ddeploy uploads-import <name> --snapshot <id> --yes

Unpacks a .zip, .tar or .tar.gz into one of <name>'s upload_dirs (as
declared in its config; `uploads-snapshot <name> --list` shows them).

  --mode merge     (default) add the archive's files, overwriting any with
                   the same path; everything else stays
  --mode replace   the folder becomes exactly the archive's contents
  --strip auto     (default) if everything is inside one folder named like
                   the upload dir (someone zipped the folder itself), unwrap it

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

cmd_uploads_import() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_uploads_import; return 0; }
    load_conf
    require_root
    local name="${1:-}" dir="" from_file="" snapshot="" mode=merge strip=auto confirm=0 delete_file=0
    [[ -n "$name" ]] || { usage_uploads_import; die "site name required"; }
    shift
    validate_name "$name"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir) dir="${2:-}"; shift ;;
            --from-file) from_file="${2:-}"; shift ;;
            --snapshot) snapshot="${2:-}"; shift ;;
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
    [[ -n "$from_file" || -n "$snapshot" ]] || die "give --from-file <archive> or --snapshot <id>"
    [[ -z "$from_file" || -z "$snapshot" ]] || die "--from-file and --snapshot are mutually exclusive"
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
        site_log "$name" "uploads-restore: $dir from $snapshot ($(notify_trigger))"
        return 0
    fi

    [[ -n "$dir" ]] || die "--dir <upload_dir> required (one of: ${UPLOAD_DIRS[*]:-none declared})"
    uploads_require_dir "$dir"
    [[ -f "$from_file" ]] || die "file not found: $from_file"
    [[ "$confirm" -eq 1 ]] || { log_warn "dry run — this would unpack $(basename "$from_file") into '$dir' ($mode). Pass --yes."; return 0; }
    event_attr kind uploads-import

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
    install -d -m 750 -o "$UPX_OWNER" -g www-data "$staging"
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

    log_info "checking and unpacking $(basename "$from_file") ($(stat -c %s "$from_file") bytes) as $UPX_OWNER"
    local summary errf rc=0
    errf="$(mktemp)"
    summary="$(sudo -u "$UPX_OWNER" -- python3 "$PROVISIONER_DIR/lib/uploads_extract.py" "$staging" \
        --max-bytes "$(( avail - reserve ))" --strip "$strip" --expect-top "$(basename "$dir")" \
        < "$from_file" 2>"$errf")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        local why; why="$(sed 's/^refused: //' "$errf" | tail -n 1)"
        rm -f "$errf"
        die "${why:-unpacking failed (exit $rc)} — nothing was changed"
    fi
    rm -f "$errf"
    local files bytes skipped stripped
    files="$(sed -E 's/.*"files": ([0-9]+).*/\1/' <<< "$summary")"
    bytes="$(sed -E 's/.*"bytes": ([0-9]+).*/\1/' <<< "$summary")"
    skipped="$(sed -E 's/.*"skipped": ([0-9]+).*/\1/' <<< "$summary")"
    stripped="$(sed -E 's/.*"stripped": "([^"]*)".*/\1/' <<< "$summary")"
    local note=""
    [[ -n "$stripped" ]] && note+=" (unwrapped the '$stripped' folder)"
    [[ "$skipped" != 0 ]] && note+=", skipped $skipped junk file(s) (__MACOSX, .DS_Store...)"
    log_info "unpacked $files file(s), $bytes bytes$note"
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
    event_attr subject "$files file(s) into $dir ($mode)${undo:+ (undo: $undo)}"
    site_log "$name" "uploads-import: $files file(s), $bytes bytes into $dir ($mode, $(notify_trigger))${undo:+ — undo snapshot $undo}"

}
