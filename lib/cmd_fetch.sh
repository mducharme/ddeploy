#!/usr/bin/env bash
# Copying upload folders from another server over SSH (`uploads-import
# --from-ssh`), and the key and host keys that uses (`fetch-key`).
#
# The server pulls: an outgoing SSH connection, like git and backups
# already make, so nothing opens on this server's firewall. The other
# server only has to accept SSH from this one, with one key:
#
#   FETCH_KEY          /etc/ddeploy/fetch-key(.pub)    ed25519, root-only
#   FETCH_KNOWN_HOSTS  /etc/ddeploy/fetch-known-hosts  host keys confirmed
#                                                      by an admin (never
#                                                      accept-new)
#
# The intended authorized_keys line on the other server is read-only and
# folder-bound (rrsync ships with rsync 3.2.4+):
#
#   command="rrsync -ro /var/www/site/uploads",restrict ssh-ed25519 AAAA… ddeploy-fetch@<host>
#
# rsync runs as root into a fresh root-only staging folder: no links,
# devices or special files, fixed permissions, total size checked by a
# dry run first; uploads-import then hands it to the site user and
# merges/replaces it like any other source.

FETCH_KEY="${FETCH_KEY:-$DDEPLOY_ETC/fetch-key}"
FETCH_KNOWN_HOSTS="${FETCH_KNOWN_HOSTS:-$DDEPLOY_ETC/fetch-known-hosts}"

FETCH_USER_RE='^[a-z_][a-z0-9_.-]{0,31}$'
# Relative to the login's home, or absolute; empty: the folder an rrsync
# key line is bound to. No spaces or shell characters (the remote path
# goes through the remote shell, or rrsync's own parsing), no '..', no
# leading '-'.
FETCH_PATH_RE='^[A-Za-z0-9._/@+~-]*$'

usage_fetch_key() {
    cat <<'EOF2'
usage: ddeploy fetch-key                     show this server's fetch key (created if missing)
       ddeploy fetch-key --forget <host> [--port <n>]   forget a remembered host key

The key `uploads-import --from-ssh` (and the web UI's "Copy from another
server") uses to read files on another server. Add its line to
~/.ssh/authorized_keys of the account it logs in as there, ideally bound
to one folder, read-only:

  command="rrsync -ro /path/to/uploads",restrict <the key>

With rrsync, give an empty path (or '.') when copying: it's relative to
that folder.
EOF2
}

fetch_key_ensure() {
    [[ -f "$FETCH_KEY" && -f "$FETCH_KEY.pub" ]] && return 0
    install -d -m 755 "$(dirname "$FETCH_KEY")"
    rm -f "$FETCH_KEY" "$FETCH_KEY.pub"
    ssh-keygen -q -t ed25519 -N '' -C "ddeploy-fetch@$(hostname -s 2>/dev/null || echo server)" -f "$FETCH_KEY" >/dev/null \
        || die "couldn't create $FETCH_KEY"
    chmod 600 "$FETCH_KEY"
    chmod 644 "$FETCH_KEY.pub"
    log_info "created the fetch key $FETCH_KEY"
}

# This server's own address, as another server would most likely see it
# (the source address of the default route). Best effort: behind NAT the
# real public address differs.
fetch_server_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -n 1
}

# $1 user, $2 host, $3 port, $4 path — dies on anything unsafe.
fetch_validate_source() {
    local user="$1" host="$2" port="$3" path="$4"
    [[ "$user" =~ $FETCH_USER_RE ]] || die "invalid SSH user '$user'"
    [[ "$host" != -* ]] || die "invalid host '$host'"
    validate_hostname "$host" "host"
    if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then die "invalid SSH port '$port'"; fi
    [[ "$path" =~ $FETCH_PATH_RE && "$path" != -* && ${#path} -le 400 ]] || die "invalid remote path '$path' — letters, digits and . _ / @ + ~ - only"
    case "/$path/" in */../*) die "remote path may not contain '..'" ;; esac
}

# Splits "user@host:path" (path may be empty) into FETCH_SRC_USER /
# FETCH_SRC_HOST / FETCH_SRC_PATH, then validates them with port $2.
fetch_parse_source() {
    local spec="$1" port="$2"
    [[ "$spec" == *@*:* ]] || die "the source is user@host:path (path may be empty), not '$spec'"
    FETCH_SRC_USER="${spec%%@*}"
    local rest="${spec#*@}"
    FETCH_SRC_HOST="${rest%%:*}"
    FETCH_SRC_PATH="${rest#*:}"
    fetch_validate_source "$FETCH_SRC_USER" "$FETCH_SRC_HOST" "$port" "$FETCH_SRC_PATH"
}

# known_hosts name for $1 host, $2 port.
fetch_host_id() {
    if [[ "$2" == 22 ]]; then printf '%s' "$1"; else printf '[%s]:%s' "$1" "$2"; fi
}

fetch_ssh_command() {
    local port="$1"
    printf 'ssh -i %s -p %s -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%s -o GlobalKnownHostsFile=/dev/null' \
        "$FETCH_KEY" "$port" "$FETCH_KNOWN_HOSTS"
}

# Scans $1 host / $2 port's host keys into file $3 (known_hosts lines).
fetch_scan() {
    local host="$1" port="$2" out="$3"
    timeout 20 ssh-keyscan -T 10 -p "$port" -t ed25519,ecdsa,rsa -- "$host" 2>/dev/null | grep -v '^#' > "$out" || true
    [[ -s "$out" ]]
}

# SHA256 fingerprints of the known_hosts lines in file $1: "type<TAB>fp".
fetch_fingerprints() {
    ssh-keygen -lf "$1" 2>/dev/null | awk '{ t=$NF; gsub(/[()]/, "", t); print t "\t" $2 }'
}

# Host-key state of $1 host / $2 port against FETCH_KNOWN_HOSTS, with the
# scanned keys left in file $3: known | unknown | changed | unreachable.
fetch_host_status() {
    local host="$1" port="$2" scan="$3" id
    id="$(fetch_host_id "$host" "$port")"
    fetch_scan "$host" "$port" "$scan" || { echo unreachable; return; }
    if [[ ! -f "$FETCH_KNOWN_HOSTS" ]] || ! ssh-keygen -F "$id" -f "$FETCH_KNOWN_HOSTS" >/dev/null 2>&1; then
        echo unknown; return
    fi
    local remembered scanned
    remembered="$(ssh-keygen -F "$id" -f "$FETCH_KNOWN_HOSTS" 2>/dev/null | grep -v '^#' | awk '{print $2" "$3}' | sort)"
    scanned="$(awk '{print $2" "$3}' "$scan" | sort)"
    # Any scanned key that matches a remembered one is the same server
    # (it may offer more key types than were remembered).
    if [[ -n "$(comm -12 <(printf '%s\n' "$remembered") <(printf '%s\n' "$scanned"))" ]]; then echo known; else echo changed; fi
}

# Remembers the scanned keys in file $3 for $1 host / $2 port, if one of
# them has fingerprint $4 (what the admin confirmed).
fetch_accept() {
    local host="$1" port="$2" scan="$3" want="$4"
    fetch_fingerprints "$scan" | cut -f2 | grep -qxF -- "$want" || die "the host's key doesn't match the fingerprint you confirmed ($want) — nothing was remembered"
    local id; id="$(fetch_host_id "$host" "$port")"
    touch "$FETCH_KNOWN_HOSTS"
    chmod 644 "$FETCH_KNOWN_HOSTS"
    ssh-keygen -R "$id" -f "$FETCH_KNOWN_HOSTS" >/dev/null 2>&1 || true
    rm -f "$FETCH_KNOWN_HOSTS.old"
    # keyscan prints the bare host; known_hosts wants [host]:port for other ports.
    awk -v id="$id" '{ $1 = id; print }' "$scan" >> "$FETCH_KNOWN_HOSTS"
}

fetch_forget() {
    local id; id="$(fetch_host_id "$1" "$2")"
    [[ -f "$FETCH_KNOWN_HOSTS" ]] || return 0
    ssh-keygen -R "$id" -f "$FETCH_KNOWN_HOSTS" >/dev/null 2>&1 || true
    rm -f "$FETCH_KNOWN_HOSTS.old"
}

# rsync's source argument for $1 user, $2 host, $4 path (trailing slash:
# the folder's contents, not the folder).
fetch_rsync_source() {
    local path="${4:-.}"
    printf '%s@%s:%s/' "$1" "$2" "${path%/}"
}

# Turns ssh/rsync stderr in file $1 into one actionable line.
fetch_explain_error() {
    local err="$1" host="$2" port="$3"
    if grep -q 'Permission denied' "$err"; then
        echo "$host refused the key — add this server's fetch key to ~/.ssh/authorized_keys of that account (see fetch-key)"
    elif grep -qE 'Connection timed out|No route to host|Network is unreachable|Connection refused' "$err"; then
        echo "can't reach $host:$port — is SSH open to this server ($(fetch_server_ip || echo 'its address'))?"
    elif grep -q 'Host key verification failed\|REMOTE HOST IDENTIFICATION HAS CHANGED' "$err"; then
        echo "$host's host key isn't confirmed (or changed) — test the connection first"
    elif grep -qE 'No such file or directory|change_dir .* failed' "$err"; then
        echo "that folder doesn't exist on $host$(grep -oE 'change_dir "[^"]*"' "$err" | head -n 1 | sed 's/change_dir / (/; s/$/)/')"
    elif grep -qE 'rrsync|not allowed|restricted' "$err"; then
        echo "the key's rrsync restriction refused this path — with rrsync, leave the path empty (it's relative to the folder the key is bound to): $(grep -v '^[[:space:]]*$' "$err" | tail -n 1)"
    else
        grep -v '^[[:space:]]*$' "$err" | grep -v '^rsync error\|^rsync: connection unexpectedly closed' | tail -n 1 | cut -c1-300
    fi
}

# Dry run of copying $1 user@$2 host:$4 path (port $3). Sets FETCH_FILES /
# FETCH_BYTES; returns 1 with the reason in FETCH_ERROR.
fetch_dry_run() {
    local user="$1" host="$2" port="$3" path="$4"
    local empty err out rc=0
    empty="$(mktemp -d)"; err="$(mktemp)"
    out="$(timeout 300 rsync -r --dry-run --stats --no-links --no-devices --no-specials --no-human-readable \
        -e "$(fetch_ssh_command "$port")" -- "$(fetch_rsync_source "$user" "$host" "$port" "$path")" "$empty/" 2>"$err")" || rc=$?
    rmdir "$empty" 2>/dev/null || true
    FETCH_ERROR=""
    if [[ "$rc" -ne 0 ]]; then
        if [[ "$rc" -eq 124 ]]; then FETCH_ERROR="listing the files on $host took over 5 minutes"
        else FETCH_ERROR="$(fetch_explain_error "$err" "$host" "$port")"; fi
        [[ -n "$FETCH_ERROR" ]] || FETCH_ERROR="rsync failed (exit $rc)"
        rm -f "$err"
        return 1
    fi
    rm -f "$err"
    FETCH_FILES="$(sed -nE 's/^Number of regular files transferred: ([0-9,]+).*/\1/p' <<< "$out" | tr -d ,)"
    [[ -n "$FETCH_FILES" ]] || FETCH_FILES="$(sed -nE 's/^Number of files: [0-9,]+ \(reg: ([0-9,]+).*/\1/p' <<< "$out" | tr -d ,)"
    FETCH_BYTES="$(sed -nE 's/^Total file size: ([0-9,]+).*/\1/p' <<< "$out" | tr -d ,)"
    FETCH_FILES="${FETCH_FILES:-0}" FETCH_BYTES="${FETCH_BYTES:-0}"
}

# Copies into $5 staging (empty, root-only). Dies on failure.
fetch_copy() {
    local user="$1" host="$2" port="$3" path="$4" staging="$5"
    local err rc=0
    err="$(mktemp)"
    # --perms --chmod: exactly these modes, whatever the source had (no
    # setuid/executable bits come across); owner and group are ours.
    rsync -r --times --no-links --no-devices --no-specials --no-owner --no-group \
        --perms --chmod=D2750,F640 --info=progress2,stats1 --no-human-readable \
        -e "$(fetch_ssh_command "$port")" -- "$(fetch_rsync_source "$user" "$host" "$port" "$path")" "$staging/" 2>"$err" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        local why; why="$(fetch_explain_error "$err" "$host" "$port")"
        rm -f "$err"
        die "copy from $host failed: ${why:-rsync exit $rc} — nothing was changed"
    fi
    rm -f "$err"
}

cmd_fetch_key() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_fetch_key; return 0; }
    load_conf
    require_root
    if [[ "${1:-}" == --forget ]]; then
        local host="${2:-}" port=22
        [[ "${3:-}" == --port ]] && port="${4:-}"
        fetch_validate_source fetch "$host" "$port" ""
        fetch_forget "$host" "$port"
        log_info "forgot $(fetch_host_id "$host" "$port")'s host key"
        return 0
    fi
    [[ $# -eq 0 ]] || die "unknown option: $1"
    fetch_key_ensure
    echo "Add this to ~/.ssh/authorized_keys of the account on the other server"
    echo "(bound to one folder, read-only — replace the path):"
    echo
    echo "command=\"rrsync -ro /path/to/uploads\",restrict $(cat "$FETCH_KEY.pub")"
    echo
    local ip; ip="$(fetch_server_ip)"
    [[ -n "$ip" ]] && echo "This server connects from $ip (unless it's behind NAT)."
}
