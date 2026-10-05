#!/usr/bin/env bash
# `api fetch-key` / `api fetch-test`: what the web UI's "Copy from another
# server" needs before it starts `run start uploads-fetch` (lib/cmd_fetch.sh).

# Host-key decisions go to the same log as server settings changes.
api_fetch_log() {
    log_line "$LOG_DIR/server-config.log" info "fetch: $1 (web ($2))" 2>/dev/null || true
}

# known_hosts entries as [{host, type, fingerprint}].
api_fetch_known_hosts_json() {
    [[ -s "$FETCH_KNOWN_HOSTS" ]] || { printf '[]'; return; }
    local first=1 line host rest tmp
    tmp="$(mktemp)"
    printf '['
    while IFS= read -r line; do
        [[ -n "$line" && "$line" != \#* ]] || continue
        host="${line%% *}"
        rest="$(printf '%s\n' "$line" > "$tmp"; fetch_fingerprints "$tmp")"
        [[ -n "$rest" ]] || continue
        [[ "$first" -eq 1 ]] || printf ','
        first=0
        printf '{"host":%s,"type":%s,"fingerprint":%s}' "$(json_str "$host")" "$(json_str "${rest%%$'\t'*}")" "$(json_str "${rest#*$'\t'}")"
    done < "$FETCH_KNOWN_HOSTS"
    printf ']'
    rm -f "$tmp"
}

# api fetch-key                         the key (created if missing) and remembered hosts
# api fetch-key forget --host h [--port n] --actor a
api_fetch_key() {
    if [[ "${1:-}" == forget ]]; then
        shift
        local host="" port=22 actor=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --host) host="${2:-}"; shift ;;
                --port) port="${2:-}"; shift ;;
                --actor) actor="${2:-}"; shift ;;
                *) api_die bad_request "fetch-key forget: unknown option '$1'" ;;
            esac
            shift
        done
        api_valid api_valid_actor "$actor"
        api_valid fetch_validate_source fetch "$host" "$port" ""
        fetch_forget "$host" "$port"
        api_fetch_log "forgot $(fetch_host_id "$host" "$port")'s host key" "$actor"
    else
        [[ $# -eq 0 ]] || api_die bad_request "fetch-key takes no arguments (or: forget --host h)"
    fi
    ( fetch_key_ensure ) >/dev/null 2>&1 || api_die error "couldn't create the fetch key"
    local pub; pub="$(cat "$FETCH_KEY.pub")"
    api_header
    printf ',"public_key":%s' "$(json_str "$pub")"
    printf ',"authorized_keys":%s' "$(json_str "command=\"rrsync -ro /path/to/uploads\",restrict $pub")"
    printf ',"server_ip":%s' "$(json_str "$(fetch_server_ip)")"
    printf ',"rsync":%s' "$(json_bool "$(command -v rsync >/dev/null 2>&1 && echo true || echo false)")"
    printf ',"known_hosts":%s}\n' "$(api_fetch_known_hosts_json)"
}

# api fetch-test <name> --source user@host:path [--port n] [--accept <SHA256:...>] --actor a
#
# The host key first: unknown or changed keys are reported with their
# fingerprints and nothing else happens, until the admin confirms one
# (--accept, which must match what the host presents right now). Then a
# dry run: how many files, how many bytes.
api_fetch_test() {
    local name="${1:-}"
    shift || true
    api_require_site "$name"
    local source="" port=22 accept="" actor=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source) source="${2:-}"; shift ;;
            --port) port="${2:-}"; shift ;;
            --accept) accept="${2:-}"; shift ;;
            --actor) actor="${2:-}"; shift ;;
            *) api_die bad_request "fetch-test: unknown option '$1'" ;;
        esac
        shift
    done
    api_valid api_valid_actor "$actor"
    api_valid fetch_parse_source "$source" "$port"
    fetch_parse_source "$source" "$port"
    [[ -z "$accept" || "$accept" =~ ^SHA256:[A-Za-z0-9+/=]{20,80}$ ]] || api_die bad_request "--accept takes a SHA256: fingerprint"
    command -v rsync >/dev/null 2>&1 || api_die conflict "rsync isn't installed on this server — re-run 'init'"
    ( fetch_key_ensure ) >/dev/null 2>&1 || api_die error "couldn't create the fetch key"

    local scan status error="" files=null bytes=null
    scan="$(mktemp)"
    status="$(fetch_host_status "$FETCH_SRC_HOST" "$port" "$scan")"
    if [[ "$status" == unknown && -n "$accept" ]]; then
        local msg
        if msg="$( (fetch_accept "$FETCH_SRC_HOST" "$port" "$scan" "$accept") 2>&1 )"; then
            status=known
            api_fetch_log "remembered $(fetch_host_id "$FETCH_SRC_HOST" "$port")'s host key ($accept)" "$actor"
        else
            error="$(sed 's/^\[error\] *//' <<< "$msg" | tail -n 1)"
        fi
    fi
    case "$status" in
        unreachable) error="can't reach $FETCH_SRC_HOST:$port — is SSH open to this server ($(fetch_server_ip || echo 'its address'))?" ;;
        changed) error="$FETCH_SRC_HOST's host key is different from the one remembered — if the server was reinstalled, forget the old key, then test again" ;;
        known)
            if fetch_dry_run "$FETCH_SRC_USER" "$FETCH_SRC_HOST" "$port" "$FETCH_SRC_PATH"; then
                files="$FETCH_FILES" bytes="$FETCH_BYTES"
            else
                error="$FETCH_ERROR"
            fi ;;
    esac

    local fps="[]" first=1 t f
    if [[ -s "$scan" ]]; then
        fps="["
        while IFS=$'\t' read -r t f; do
            [[ "$first" -eq 1 ]] || fps+=","
            first=0
            fps+="{\"type\":$(json_str "$t"),\"fingerprint\":$(json_str "$f")}"
        done < <(fetch_fingerprints "$scan")
        fps+="]"
    fi
    rm -f "$scan"
    api_header
    printf ',"host":%s,"port":%s' "$(json_str "$FETCH_SRC_HOST")" "$(json_num "$port")"
    printf ',"host_key":{"status":%s,"fingerprints":%s}' "$(json_str "$status")" "$fps"
    printf ',"files":%s,"bytes":%s' "$files" "$bytes"
    printf ',"error":%s}\n' "$( [[ -n "$error" ]] && json_str "$error" || echo null )"
}
