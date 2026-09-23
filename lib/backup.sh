#!/usr/bin/env bash
# Backs up each site's declared upload_dirs (.ddev/config.yaml's own key,
# or the sidecar's — set_sidecar_upload_dirs in config.sh) to object
# storage via rclone. Disaster-recovery only: local disk stays the copy
# actually served, this is a one-way sync out. Nothing here runs unless
# BACKUP_ENABLED=true and a site has upload_dirs declared.

require_rclone() {
    command -v rclone >/dev/null 2>&1 || die "rclone not found — run 'init' first, or install it manually"
}

require_backup_credentials() {
    [[ -n "$BACKUP_CREDENTIALS" ]] || die "provisioner.conf: BACKUP_CREDENTIALS not set"
    [[ -f "$BACKUP_CREDENTIALS" ]] || die "BACKUP_CREDENTIALS file not found: $BACKUP_CREDENTIALS"
    [[ -n "$BACKUP_BUCKET" ]] || die "provisioner.conf: BACKUP_BUCKET not set"
}

# Regenerates $RCLONE_CONFIG (lib/common.sh) from BACKUP_CREDENTIALS (a
# shell file defining BACKUP_ENDPOINT/BACKUP_ACCESS_KEY/BACKUP_SECRET_KEY)
# on every call — always fresh, so a rotated key in BACKUP_CREDENTIALS
# takes effect on the very next backup/restore/list without a separate
# sync step, same property the old inline-spec version of this function
# had. provider=Other + an explicit endpoint works generically across
# S3/Spaces/B2/MinIO/etc. Prints "<remote-name>:<bucket>" — every caller
# already just interpolates this into "${remote}/..." unchanged, so
# nothing else needed to change to stop building an inline connection
# string (see RCLONE_CONFIG's own comment for why that was a problem).
BACKUP_RCLONE_REMOTE="ddeploy-backup"

backup_remote_spec() {
    # shellcheck source=/dev/null
    source "$BACKUP_CREDENTIALS"
    : "${BACKUP_ENDPOINT:?$BACKUP_CREDENTIALS: BACKUP_ENDPOINT not set}"
    : "${BACKUP_ACCESS_KEY:?$BACKUP_CREDENTIALS: BACKUP_ACCESS_KEY not set}"
    : "${BACKUP_SECRET_KEY:?$BACKUP_CREDENTIALS: BACKUP_SECRET_KEY not set}"
    mkdir -p "$(dirname "$RCLONE_CONFIG")"
    local tmp; tmp="$(mktemp)"
    cat > "$tmp" <<EOF
[$BACKUP_RCLONE_REMOTE]
type = s3
provider = Other
env_auth = false
access_key_id = $BACKUP_ACCESS_KEY
secret_access_key = $BACKUP_SECRET_KEY
endpoint = $BACKUP_ENDPOINT
EOF
    chmod 600 "$tmp"
    mv "$tmp" "$RCLONE_CONFIG"
    echo "${BACKUP_RCLONE_REMOTE}:${BACKUP_BUCKET}"
}

# $1 name, $2 site dir, remaining args: upload dirs (relative to $2).
# No-op if the site has none declared. Returns nonzero if any directory
# failed to sync — but still attempts every directory regardless, since
# a bare `rclone sync` failing partway through would otherwise abort the
# rest of this site's own dirs under set -e, not just move on to the
# next site (that part's the caller's job, via its own if-wrapped call).
# Excludes are read from the BACKUP_EXCLUDE[] global (set by parse_config
# from .ddeploy/config.yaml's backup_exclude: — the caller always runs
# parse_config/resolve_preview_config immediately before this, same
# pattern UPLOAD_DIRS/PERSISTENT_FILES already use). Not applied to
# restore_site_uploads below — a restore only ever pulls back what
# actually made it to object storage, so excluded content was never
# there to restore in the first place.
backup_site_uploads() {
    local name="$1" dir="$2"; shift 2
    local dirs=("$@")
    [[ "${#dirs[@]}" -gt 0 ]] || return 0

    require_rclone
    require_backup_credentials
    local remote; remote="$(backup_remote_spec)"

    local -a exclude_args=()
    local pattern
    for pattern in "${BACKUP_EXCLUDE[@]}"; do
        exclude_args+=(--exclude "$pattern")
    done

    local d src failures=0
    for d in "${dirs[@]}"; do
        src="$dir/$d"
        if [[ ! -d "$src" ]]; then
            log_warn "backup: $name: $d does not exist, skipping"
            continue
        fi
        log_info "backup: $name: $d -> $BACKUP_BUCKET/$name/$d"
        if ! rclone sync "$src" "${remote}/$name/$d" --checksum "${exclude_args[@]}"; then
            log_warn "backup: $name: $d failed to sync"
            failures=$((failures + 1))
        fi
    done
    [[ "$failures" -eq 0 ]]
}

# The reverse of backup_site_uploads: downloads the current backed-up
# state of each dir, OVERWRITING whatever's on local disk now. Same
# per-directory resilience as the backup direction — one dir failing
# doesn't stop the others from being attempted.
restore_site_uploads() {
    local name="$1" dir="$2"; shift 2
    local dirs=("$@")
    [[ "${#dirs[@]}" -gt 0 ]] || return 0

    require_rclone
    require_backup_credentials
    local remote; remote="$(backup_remote_spec)"

    local d dest failures=0
    for d in "${dirs[@]}"; do
        dest="$dir/$d"
        log_info "restore: $name: $BACKUP_BUCKET/$name/$d -> $dest"
        mkdir -p "$dest"
        if ! rclone sync "${remote}/$name/$d" "$dest" --checksum; then
            log_warn "restore: $name: $d failed to restore"
            failures=$((failures + 1))
        fi
    done
    [[ "$failures" -eq 0 ]]
}
