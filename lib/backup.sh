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

# Builds an inline S3-compatible rclone remote from BACKUP_CREDENTIALS (a
# shell file defining BACKUP_ENDPOINT/BACKUP_ACCESS_KEY/BACKUP_SECRET_KEY)
# — no persistent rclone config file needed. provider=Other + an explicit
# endpoint works generically across S3/Spaces/B2/MinIO/etc. Values are
# double-quoted: rclone's inline connection-string syntax treats ':' as a
# structural delimiter, which an unquoted "https://..." endpoint collides
# with (confirmed — an unquoted endpoint fails with "Custom endpoint
# `https` was not a valid URI").
backup_remote_spec() {
    # shellcheck source=/dev/null
    source "$BACKUP_CREDENTIALS"
    : "${BACKUP_ENDPOINT:?$BACKUP_CREDENTIALS: BACKUP_ENDPOINT not set}"
    : "${BACKUP_ACCESS_KEY:?$BACKUP_CREDENTIALS: BACKUP_ACCESS_KEY not set}"
    : "${BACKUP_SECRET_KEY:?$BACKUP_CREDENTIALS: BACKUP_SECRET_KEY not set}"
    echo ":s3,provider=Other,env_auth=false,access_key_id=\"${BACKUP_ACCESS_KEY}\",secret_access_key=\"${BACKUP_SECRET_KEY}\",endpoint=\"${BACKUP_ENDPOINT}\":${BACKUP_BUCKET}"
}

# $1 name, $2 site dir, remaining args: upload dirs (relative to $2).
# No-op if the site has none declared.
backup_site_uploads() {
    local name="$1" dir="$2"; shift 2
    local dirs=("$@")
    [[ "${#dirs[@]}" -gt 0 ]] || return 0

    require_rclone
    require_backup_credentials
    local remote; remote="$(backup_remote_spec)"

    local d src
    for d in "${dirs[@]}"; do
        src="$dir/$d"
        if [[ ! -d "$src" ]]; then
            log_warn "backup: $name: $d does not exist, skipping"
            continue
        fi
        log_info "backup: $name: $d -> $BACKUP_BUCKET/$name/$d"
        rclone sync "$src" "${remote}/$name/$d" --checksum
    done
}
