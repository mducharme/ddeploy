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
    [[ -n "$BACKUP_BUCKET" ]] || die "BACKUP_BUCKET not set (in $BACKUP_CREDENTIALS, next to BACKUP_ENDPOINT)"
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

# BACKUP_ENDPOINT from the credentials file. (backup_remote_spec sources it
# too, but callers run that in $(...), so the variable stays in the subshell.)
backup_endpoint() {
    # shellcheck source=/dev/null
    ( source "$BACKUP_CREDENTIALS" 2>/dev/null; printf '%s\n' "${BACKUP_ENDPOINT:-}" )
}

# $1 endpoint URL, $2 bucket. Prints the corrected endpoint (and returns 0)
# when the endpoint already names the bucket as its first host label —
# DigitalOcean's "Origin Endpoint" (https://<space>.tor1.digitaloceanspaces.com)
# or a virtual-hosted S3 URL. rclone adds the bucket again, so uploads land
# under <bucket>/<bucket>/... while listings of <bucket>/<site>/ come back
# empty: every backup "succeeds" and none can be found. Returns 1 if fine.
backup_endpoint_with_bucket() {
    local endpoint="$1" bucket="$2"
    [[ -n "$endpoint" && -n "$bucket" ]] || return 1
    local scheme="" rest="$endpoint"
    if [[ "$rest" == *"://"* ]]; then scheme="${rest%%://*}://"; rest="${rest#*://}"; fi
    local host="${rest%%/*}" path=""
    [[ "$rest" == */* ]] && path="/${rest#*/}"
    local first="${host%%.*}"
    [[ "$host" == *.* && "${first,,}" == "${bucket,,}" ]] || return 1
    printf '%s%s%s\n' "$scheme" "${host#*.}" "${path%/}"
}

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
        # Versioned: whatever this sync would overwrite or delete in the
        # mirror is moved to <site>/.versions/<run>/<dir>/ instead, so a
        # file deleted (or broken) on the site is still recoverable for
        # UPLOADS_BACKUP_VERSIONS_DAYS. 0 = plain mirror, as before.
        local -a version_args=()
        if [[ "${UPLOADS_BACKUP_VERSIONS_DAYS:-30}" != 0 ]]; then
            version_args=(--backup-dir "${remote}/$name/.versions/${BACKUP_RUN_TS:-$(date -u +%Y%m%dT%H%M%SZ)}/$d")
        fi
        if ! rclone sync "$src" "${remote}/$name/$d" --checksum "${exclude_args[@]}" "${version_args[@]}"; then
            log_warn "backup: $name: $d failed to sync"
            failures=$((failures + 1))
        fi
    done
    [[ "$failures" -eq 0 ]] && prune_uploads_versions "$name" "$remote"
    [[ "$failures" -eq 0 ]]
}

# Version folders are named by run (UTC timestamp): drops those older than
# UPLOADS_BACKUP_VERSIONS_DAYS.
UPLOADS_VERSION_ID_RE='^[0-9]{8}T[0-9]{6}Z$'
prune_uploads_versions() {
    local name="$1" remote="$2"
    local days="${UPLOADS_BACKUP_VERSIONS_DAYS:-30}"
    [[ "$days" =~ ^[1-9][0-9]{0,3}$ ]] || return 0
    local cutoff; cutoff="$(date -u -d "-${days} days" +%Y%m%dT%H%M%SZ)"
    local v
    while IFS= read -r v; do
        v="${v%/}"
        [[ "$v" =~ $UPLOADS_VERSION_ID_RE && "$v" < "$cutoff" ]] || continue
        rclone purge "${remote}/$name/.versions/$v" 2>/dev/null || log_warn "backup: $name: couldn't prune version $v"
    done < <(rclone lsf --dirs-only "${remote}/$name/.versions/" 2>/dev/null)
    return 0
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
