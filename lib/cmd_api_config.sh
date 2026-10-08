#!/usr/bin/env bash
# `api config` / `api config set` — the server settings a web UI
# super-admin may change in /etc/ddeploy/provisioner.conf.
#
# provisioner.conf is `source`d by root on every command, so this is the
# most sensitive write the api offers. Hence:
#   - an allowlist of keys (API_CONFIG_KEYS); paths, credentials, domains,
#     the database server and anything else structural stay CLI-only
#   - every value checked by its key's own validator, on top of a charset
#     that excludes everything a double-quoted shell string interprets
#     ($, backtick, backslash, quotes) and newlines
#   - values on stdin, never argv (NOTIFY_WEBHOOK is a secret)
#   - a dated backup of the file first; if it no longer loads afterwards,
#     it's put back and the change refused
#   - what the change needs applied is applied: cron jobs for schedules and
#     *_ENABLED flags, the web UI's vhost for its upload limits. Site
#     defaults apply to each site's next deploy.

# KEY:validator:apply  (apply: deploy | now | cron | web)
API_CONFIG_KEYS=(
    BASIC_AUTH_DEFAULT:bool:deploy
    BASIC_AUTH_ALLOW_IPS:ips:deploy
    CLIENT_MAX_BODY_SIZE:body:deploy
    FPM_MAX_CHILDREN:children:deploy
    DEFAULT_PHP:php:deploy
    DEFAULT_NODE:node:deploy
    RELEASES_KEEP:int1-50:deploy
    PREVIEW_DB_MODE:previewmode:now
    PREVIEW_SEED:bool:now
    PREVIEW_BRANCHES:patterns:now
    PREVIEW_PRUNE_ENABLED:bool:cron
    PREVIEW_PRUNE_SCHEDULE:cron:cron
    DOCTOR_SCHEDULE:cron:cron
    BACKUP_ENABLED:bool:cron
    BACKUP_SCHEDULE:cron:cron
    DB_BACKUP_ENABLED:bool:cron
    DB_BACKUP_SCHEDULE:cron:cron
    DB_BACKUP_RETENTION_DAYS:int1-9999:now
    UPLOADS_BACKUP_VERSIONS_DAYS:int0-9999:now
    NOTIFY_WEBHOOK:url:now
    NOTIFY_EVENTS:events:now
    NOTIFY_COOLDOWN:int0-604800:now
    RUN_LOG_RETENTION_DAYS:int1-3650:now
    DB_SNAPSHOT_KEEP:int1-50:now
    UPLOADS_SNAPSHOT_KEEP:int1-50:now
    WEB_IMPORT_MAX_MB:int1-1048576:web
    WEB_UPLOAD_MAX_MB:int1-1048576:web
    NODE_BUILD_TIMEOUT:int60-86400:now
    NODE_BUILD_MEMORY_MAX:memory:now
)
# Shown, never editable here.
API_CONFIG_READONLY=(BASE_DOMAIN SITES_ROOT PERSISTENT_ROOT DB_HOST BASELINE_PHP BASELINE_NODE WEBHOOK_ENABLED WEBHOOK_HOSTNAME WEB_HOSTNAME BACKUP_BUCKET CLOUDFLARE_PROXIED)
API_CONFIG_SECRETS=" NOTIFY_WEBHOOK "
API_CONFIG_EVENTS="deploy-success deploy-failure preview-created preview-removed webhook-rejected"

api_config_spec() {
    local key="$1" entry
    for entry in "${API_CONFIG_KEYS[@]}"; do
        [[ "${entry%%:*}" == "$key" ]] && { printf '%s' "$entry"; return 0; }
    done
    return 1
}

# Dies unless $2 is an acceptable value for key $1.
api_config_validate() {
    local key="$1" val="$2" spec validator
    spec="$(api_config_spec "$key")" || die "'$key' can't be changed from here"
    validator="$(cut -d: -f2 <<< "$spec")"
    # Nothing a double-quoted shell string would interpret, ever.
    [[ "$val" != *[\$\`\\\"\']* && "$val" != *$'\n'* && "$val" != *$'\r'* ]] || die "$key: value contains a character that isn't allowed (\$ \` \\ quotes, newlines)"
    case "$validator" in
        bool) [[ "$val" == true || "$val" == false ]] || die "$key: true or false" ;;
        body) validate_body_size "$val" "$key"; [[ -n "$val" ]] || die "$key: required" ;;
        children) validate_max_children "$val" "$key"; [[ -n "$val" ]] || die "$key: required" ;;
        php) validate_php_version "$val" "$key" ;;
        node) validate_node_version_spec "$val" "$key" ;;
        cron) validate_cron_expr "$val" "$key" ;;
        previewmode) [[ "$val" == shared || "$val" == isolated ]] || die "$key: shared or isolated" ;;
        patterns)
            local p
            for p in $val; do validate_branch_pattern "$p" "$key entry"; done ;;
        ips)
            local ip
            for ip in $val; do validate_ip_allow_entry "$ip" "$key entry"; done ;;
        url) [[ -z "$val" || "$val" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/?=\&%+:@-]*)?$ ]] || die "$key: an https:// URL (or empty, to turn it off)" ;;
        events)
            local e
            for e in $val; do [[ " $API_CONFIG_EVENTS " == *" $e "* ]] || die "$key: unknown event '$e' (known: $API_CONFIG_EVENTS)"; done ;;
        memory) [[ -z "$val" || "$val" =~ ^[1-9][0-9]*[KMG]?$ ]] || die "$key: like 2G or 1536M (or empty for no cap)" ;;
        int*)
            local range="${validator#int}" lo hi
            lo="${range%-*}" hi="${range#*-}"
            # 10#: "08" is a number here, not bad octal.
            if ! [[ "$val" =~ ^[0-9]{1,9}$ ]] || (( 10#$val < lo || 10#$val > hi )); then
                die "$key: a whole number from $lo to $hi"
            fi ;;
        *) die "$key: no validator" ;;
    esac
}

# Is KEY set explicitly in provisioner.conf (rather than defaulted)?
api_config_explicit() {
    grep -qE "^$1=" "$CONF_FILE"
}

# Sets KEY="value" in provisioner.conf: replaces its line (keeping a
# trailing comment) or appends it. Values pass through ENVIRON, never as
# awk -v (which would expand backslash escapes) — though validation has
# already ruled those out.
api_config_write() {
    local key="$1" val="$2" tmp
    tmp="$(mktemp "$CONF_FILE.XXXXXX")"
    if api_config_explicit "$key"; then
        K="$key" V="$val" awk '
            BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
            index($0, k "=") == 1 {
                rest = ""
                if (match($0, /"[[:space:]]+#.*$/)) rest = substr($0, RSTART + 1)
                print k "=\"" v "\"" rest
                next
            }
            { print }
        ' "$CONF_FILE" > "$tmp"
    else
        cat "$CONF_FILE" > "$tmp"
        grep -q '^# --- set from the web UI' "$tmp" || printf '\n# --- set from the web UI (ddeploy api config set) ---\n' >> "$tmp"
        printf '%s="%s"\n' "$key" "$val" >> "$tmp"
    fi
    chmod 644 "$tmp"
    chown root:root "$tmp"
    mv "$tmp" "$CONF_FILE"
}

api_config_json() {
    local entry key validator apply val first=1
    api_header
    printf ',"file":%s,"settings":[' "$(json_str "$CONF_FILE")"
    for entry in "${API_CONFIG_KEYS[@]}"; do
        IFS=: read -r key validator apply <<< "$entry"
        val="${!key:-}"
        [[ "$first" -eq 1 ]] || printf ','
        first=0
        if [[ "$API_CONFIG_SECRETS" == *" $key "* ]]; then
            printf '{"key":%s,"value":"","secret":true,"is_set":%s,"explicit":%s,"apply":%s}' "$(json_str "$key")" \
                "$([[ -n "$val" ]] && echo true || echo false)" "$(api_config_explicit "$key" && echo true || echo false)" "$(json_str "$apply")"
        else
            printf '{"key":%s,"value":%s,"secret":false,"is_set":%s,"explicit":%s,"apply":%s}' "$(json_str "$key")" "$(json_str "$val")" \
                "$([[ -n "$val" ]] && echo true || echo false)" "$(api_config_explicit "$key" && echo true || echo false)" "$(json_str "$apply")"
        fi
    done
    printf '],"readonly":{'
    first=1
    for key in "${API_CONFIG_READONLY[@]}"; do
        [[ "$first" -eq 1 ]] || printf ','
        first=0
        printf '%s:%s' "$(json_str "$key")" "$(json_str "${!key:-}")"
    done
    printf '},"backups_configured":%s}\n' \
        "$([[ -n "$BACKUP_CREDENTIALS" && -f "$BACKUP_CREDENTIALS" && -n "$BACKUP_BUCKET" ]] && echo true || echo false)"
}

api_config() {
    local sub="${1:-}"
    case "$sub" in
        "") api_config_json ;;
        set) shift; api_config_set "$@" ;;
        *) api_die bad_request "config: expected nothing or 'set'" ;;
    esac
}

api_config_set() {
    local actor=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --actor) actor="${2:-}"; shift ;;
            *) api_die bad_request "config set: unexpected argument '$1'" ;;
        esac
        shift
    done
    api_valid api_valid_actor "$actor"
    [[ ! -t 0 ]] || api_die bad_request "config set reads KEY=value lines from stdin"

    # 1. Read and validate everything before touching the file.
    local -a keys=() vals=()
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        [[ "$line" == *=* ]] || api_die bad_request "stdin lines must be KEY=value"
        key="${line%%=*}" val="${line#*=}"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || api_die bad_request "invalid key '$key'"
        api_valid api_config_validate "$key" "$val"
        keys+=("$key") vals+=("$val")
    done
    [[ "${#keys[@]}" -gt 0 ]] || api_die bad_request "nothing to change"

    local i changed="" cron=0 web=0 apply
    for i in "${!keys[@]}"; do
        key="${keys[i]}" val="${vals[i]}"
        [[ "${!key:-}" == "$val" ]] && api_config_explicit "$key" && continue
        changed+="${changed:+ }$key"
        apply="$(api_config_spec "$key" | cut -d: -f3)"
        [[ "$apply" == cron ]] && cron=1
        [[ "$apply" == web ]] && web=1
        if [[ "$key" == BACKUP_ENABLED || "$key" == DB_BACKUP_ENABLED ]] && [[ "$val" == true ]]; then
            [[ -n "$BACKUP_CREDENTIALS" && -f "$BACKUP_CREDENTIALS" && -n "$BACKUP_BUCKET" ]] \
                || api_die bad_request "object storage isn't set up — run 'ddeploy configure backups' on the server first"
            command -v rclone >/dev/null 2>&1 || api_die bad_request "rclone isn't installed — run 'ddeploy configure backups' / 'ddeploy init' on the server first"
        fi
    done
    if [[ -z "$changed" ]]; then
        api_config_json
        return 0
    fi

    # 2. Back up, write, and make sure the file still loads.
    local backup; backup="$CONF_FILE.bak-$(date -u +%Y%m%dT%H%M%SZ)"
    install -m 600 -o root -g root "$CONF_FILE" "$backup"
    find "$(dirname "$CONF_FILE")" -maxdepth 1 -name "$(basename "$CONF_FILE").bak-*" -printf '%f\n' | sort -r | tail -n +11 \
        | while IFS= read -r old; do rm -f "$(dirname "$CONF_FILE")/$old"; done
    for i in "${!keys[@]}"; do api_config_write "${keys[i]}" "${vals[i]}"; done
    local err
    if ! err="$( (load_conf) 2>&1 )"; then
        cat "$backup" > "$CONF_FILE"
        err="$(tail -n 1 <<< "$err")"
        api_die bad_request "the change would leave provisioner.conf unloadable (${err#\[error\] }) — nothing was changed"
    fi
    load_conf

    # 3. Apply what needs applying.
    local applied=""
    if [[ "$cron" -eq 1 ]]; then
        install_cron_jobs >/dev/null 2>&1 || log_warn "couldn't rewrite the cron jobs — run 'ddeploy init' to retry"
        applied+="${applied:+, }cron jobs"
    fi
    if [[ "$web" -eq 1 && -f /etc/nginx/sites-available/ddeploy-web.conf ]]; then
        if install_web >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
            systemctl reload nginx
            applied+="${applied:+, }web UI vhost"
        else
            cat "$backup" > "$CONF_FILE"
            load_conf
            install_web >/dev/null 2>&1 || true
            api_die unavailable "the new limits broke the web UI's nginx config — provisioner.conf put back"
        fi
    fi
    mkdir -p "$LOG_DIR"
    log_line "$LOG_DIR/server-config.log" ok "config: set $changed (web ($actor))${applied:+ — applied: $applied}"
    api_config_json
}
