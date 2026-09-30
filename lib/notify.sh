#!/usr/bin/env bash
# Chat notifications: deploy success/failure, previews created/removed,
# rejected webhooks, and failure paging for unattended commands (backup
# cron, prune-previews, doctor). Empty URL is a no-op, and a dead URL
# never fails the job that sent the message.
#
# Where a message goes:
#   - NOTIFY_WEBHOOK (provisioner.conf) — the server-wide channel, gets
#     everything.
#   - a per-site URL (`ddeploy notify <name> --set-url`), stored
#     root-only in generated/<name>.notify-url — that site's own events
#     also go there (a client channel, say). A preview uses its parent's.
# Which events are sent at all: NOTIFY_EVENTS (provisioner.conf).
#
# Slack incoming webhooks (hooks.slack.com) and Discord webhooks get
# their native formatting (colored attachment / embed); any other URL
# gets a flat JSON object with text/content plus the raw fields.
#
# Webhook URLs are credentials — this file must never log one.

NOTIFY_STATE_DIR="/var/lib/ddeploy/notify"
NOTIFY_COOLDOWN_DEFAULT=3600
NOTIFY_EVENTS_DEFAULT="deploy-success deploy-failure preview-created preview-removed webhook-rejected"

notify_site_url_path() { echo "$GENERATED_DIR/$1.notify-url"; }

# Prints each URL a message about site $1 (may be empty) should go to,
# one per line, deduplicated: the site's own (or, for a preview, its
# parent's) first, then the server-wide one.
notify_urls() {
    local site="${1:-}" own=""
    if [[ -n "$site" ]]; then
        local f; f="$(notify_site_url_path "$site")"
        if [[ ! -s "$f" ]] && read_preview_meta "$site" 2>/dev/null; then
            f="$(notify_site_url_path "$PREVIEW_PROJECT")"
        fi
        [[ -s "$f" ]] && own="$(head -n1 "$f")"
    fi
    [[ -n "$own" ]] && printf '%s\n' "$own"
    if [[ -n "${NOTIFY_WEBHOOK:-}" && "${NOTIFY_WEBHOOK}" != "$own" ]]; then
        printf '%s\n' "$NOTIFY_WEBHOOK"
    fi
}

# $1 cooldown key. Returns 0 (and records now) if a message may be sent,
# 1 if the same key was sent within NOTIFY_COOLDOWN seconds.
notify_cooldown_ok() {
    local key; key="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
    local cooldown="${NOTIFY_COOLDOWN:-$NOTIFY_COOLDOWN_DEFAULT}"
    [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown="$NOTIFY_COOLDOWN_DEFAULT"
    mkdir -p "$NOTIFY_STATE_DIR"
    chmod 700 "$NOTIFY_STATE_DIR" 2>/dev/null || true
    local stamp="$NOTIFY_STATE_DIR/$key"
    if [[ "$cooldown" -gt 0 && -f "$stamp" ]]; then
        local now mtime age
        now="$(date +%s)"
        mtime="$(stat -c %Y "$stamp" 2>/dev/null || echo 0)"
        age=$((now - mtime))
        if [[ "$age" -ge 0 && "$age" -lt "$cooldown" ]]; then
            log_info "notify: skipping '$1' — last sent ${age}s ago (cooldown ${cooldown}s)"
            return 1
        fi
    fi
    date +%s > "$stamp"
    chmod 600 "$stamp" 2>/dev/null || true
    return 0
}

# POSTs one message to one URL. $1 url $2 status (ok|fail|info) $3 title
# $4 details (may be multi-line) $5 event $6 site. Returns nonzero on
# failure; callers decide what that means (always: nothing fatal).
notify_post() {
    local url="$1" status="$2" title="$3" details="$4" event="$5" site="$6"
    # Discord caps content at 2000 chars, Slack attachments are
    # generous but a whole build log is still noise.
    if [[ "${#details}" -gt 1500 ]]; then
        details="${details:0:1500}..."
    fi
    DDEPLOY_NOTIFY_URL="$url" \
    DDEPLOY_NOTIFY_STATUS="$status" \
    DDEPLOY_NOTIFY_TITLE="$title" \
    DDEPLOY_NOTIFY_DETAILS="$details" \
    DDEPLOY_NOTIFY_EVENT="$event" \
    DDEPLOY_NOTIFY_SITE="$site" \
    DDEPLOY_NOTIFY_HOST="${BASE_DOMAIN:-unknown}" \
    python3 -c '
import json, os, sys, urllib.error, urllib.parse, urllib.request
e = os.environ.get
url = e("DDEPLOY_NOTIFY_URL", "")
if not url:
    sys.exit(1)
status, title, details = e("DDEPLOY_NOTIFY_STATUS", "info"), e("DDEPLOY_NOTIFY_TITLE", ""), e("DDEPLOY_NOTIFY_DETAILS", "")
host = e("DDEPLOY_NOTIFY_HOST", "")
color = {"ok": "#2eb67d", "fail": "#e01e5a"}.get(status, "#6b7280")
footer = "ddeploy on " + host
netloc = urllib.parse.urlparse(url).netloc.lower()
flat = title + (": " + details.replace("\n", " — ") if details else "")
if netloc == "hooks.slack.com":
    payload = {"text": title, "attachments": [
        {"color": color, "text": details, "footer": footer, "mrkdwn_in": ["text"]}]}
elif netloc.endswith("discord.com") or netloc.endswith("discordapp.com"):
    payload = {"content": "", "embeds": [
        {"title": title, "description": details, "color": int(color[1:], 16), "footer": {"text": footer}}]}
else:
    payload = {"text": flat, "content": flat, "host": host, "event": e("DDEPLOY_NOTIFY_EVENT", ""),
               "site": e("DDEPLOY_NOTIFY_SITE", ""), "status": status, "title": title, "detail": details,
               "command": e("DDEPLOY_NOTIFY_EVENT", "")}
req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"),
                             headers={"Content-Type": "application/json", "User-Agent": "ddeploy-notify"},
                             method="POST")
try:
    with urllib.request.urlopen(req, timeout=8) as resp:
        if getattr(resp, "status", 200) >= 400:
            sys.exit(1)
except (urllib.error.URLError, TimeoutError, ValueError, OSError):
    sys.exit(1)
' >/dev/null 2>&1
}

# Sends one event. $1 event (see NOTIFY_EVENTS_DEFAULT) $2 site (may be
# empty) $3 title $4 details $5 "cooldown" to rate-limit this
# event+site by NOTIFY_COOLDOWN (for things that can repeat on a loop,
# like a misconfigured webhook secret). Always returns 0.
notify_event() {
    local event="$1" site="${2:-}" title="$3" details="${4:-}" limit="${5:-}"
    local enabled="${NOTIFY_EVENTS:-$NOTIFY_EVENTS_DEFAULT}"
    [[ " $enabled " == *" $event "* ]] || return 0

    local -a urls=()
    mapfile -t urls < <(notify_urls "$site")
    [[ "${#urls[@]}" -gt 0 ]] || return 0

    if [[ "$limit" == "cooldown" ]]; then
        notify_cooldown_ok "${event}_${site}" || return 0
    fi

    local status=info
    case "$event" in
        *-success|preview-created) status=ok ;;
        *-failure|*-rejected) status=fail ;;
    esac

    local url
    for url in "${urls[@]}"; do
        notify_post "$url" "$status" "$title" "$details" "$event" "$site" \
            || log_warn "notify: POST failed for '$event'${site:+ $site} — check the webhook URL (not logged)"
    done
    return 0
}

# Failure paging for unattended commands (backup-uploads,
# backup-database, prune-previews, doctor): server-wide channel only,
# rate-limited per command+site. Not gated by NOTIFY_EVENTS — this is
# the original, always-on use of NOTIFY_WEBHOOK.
# $1 command  $2 site (optional)  $3 detail (optional)
notify_failure() {
    local command="$1" site="${2:-}" detail="${3:-}"
    [[ -n "${NOTIFY_WEBHOOK:-}" ]] || return 0
    [[ -n "$command" ]] || return 0
    notify_cooldown_ok "${command}_${site}" || return 0
    local title="ddeploy ${command} failed on ${BASE_DOMAIN:-unknown}${site:+ (${site})}"
    notify_post "$NOTIFY_WEBHOOK" fail "$title" "$detail" "$command" "$site" \
        || log_warn "notify: POST failed for '$command'${site:+ $site} — check NOTIFY_WEBHOOK (URL is not logged)"
    return 0
}

# Last lines of a log file, flattened, for a message's detail field.
notify_log_snippet() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    tail -n 8 "$file" 2>/dev/null | tr '\n' ' ' | cut -c1-400 || true
}

# Human description of who/what started this run, for messages:
# "webhook [ab12cd34]" (set by hook-worker), else the sudo user.
notify_trigger() {
    if [[ -n "${DDEPLOY_TRIGGER:-}" ]]; then
        printf '%s' "$DDEPLOY_TRIGGER"
    elif [[ -n "${SUDO_USER:-}" ]]; then
        printf 'manual (%s)' "$SUDO_USER"
    else
        printf 'manual'
    fi
}

# Success message for a deploy / deploy-preview / provision-preview.
# $1 event $2 site $3 checkout dir $4 seconds taken $5 verb ("deployed",
# "rolled back", "preview created")
notify_deploy_success() {
    local event="$1" site="$2" dir="$3" took="$4" verb="$5"
    local commit
    commit="$(git -c safe.directory='*' -C "$dir" log -1 --format='%h %s (%an)' 2>/dev/null | cut -c1-200 || true)"
    local details="https://$site.$BASE_DOMAIN"
    [[ -n "$commit" ]] && details+=$'\n'"Commit: $commit"
    details+=$'\n'"Took ${took}s — $(notify_trigger)"
    notify_event "$event" "$site" "$site $verb" "$details"
}

# `notify <name> ...` — per-site notification URL (a client's own Slack
# channel, say). Reads the URL from stdin, never argv (argv shows up in
# `ps` and shell history).
usage_notify() {
    cat <<'EOF'
usage: ddeploy notify <name> [--set-url | --unset | --show | --test]
       ddeploy notify --test

Per-site chat webhook (Slack incoming webhook, Discord, or anything that
accepts a JSON POST). That site's events (deploys, failures, its
previews) go there in addition to the server-wide NOTIFY_WEBHOOK. A
preview uses its parent's URL unless it has its own.

  --set-url   read the URL from stdin (prompted when interactive), e.g.
              echo "$URL" | ddeploy notify mysite --set-url
  --unset     remove this site's URL
  --show      say whether a URL is set (the URL itself is not printed)
  --test      send a test message to every URL this site's events use
              (without a name: to NOTIFY_WEBHOOK)

Which events are sent: NOTIFY_EVENTS in provisioner.conf.
EOF
}

cmd_notify() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" || -z "${1:-}" ]] && { usage_notify; return 0; }
    load_conf
    require_root

    local name="" action=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --set-url|--unset|--show|--test)
                [[ -z "$action" ]] || die "notify: give one of --set-url / --unset / --show / --test"
                action="${1#--}"
                ;;
            -h|--help) usage_notify; return 0 ;;
            -*) die "unknown option: $1" ;;
            *) [[ -z "$name" ]] || die "notify: extra argument '$1'"; name="$1" ;;
        esac
        shift
    done
    [[ -n "$action" ]] || action="show"
    [[ -n "$name" ]] && validate_name "$name"
    [[ -n "$name" || "$action" == "test" ]] || die "notify: site name required"

    local f=""
    [[ -n "$name" ]] && f="$(notify_site_url_path "$name")"

    case "$action" in
        set-url)
            local url=""
            if [[ -t 0 ]]; then
                read -rsp "Webhook URL for '$name' (input hidden): " url
                echo >&2
            else
                IFS= read -r url || true
            fi
            [[ "$url" =~ ^https?://[^[:space:]]+$ ]] || die "notify: expected an https:// URL"
            mkdir -p "$GENERATED_DIR"
            install -m 600 -o root -g root /dev/null "$f"
            printf '%s\n' "$url" > "$f"
            log_info "'$name': notification URL saved (root-only, $f) — try it with 'ddeploy notify $name --test'"
            ;;
        unset)
            rm -f "$f"
            log_info "'$name': notification URL removed"
            ;;
        show)
            if [[ -s "$f" ]]; then
                log_info "'$name': own notification URL is set (host: $(head -n1 "$f" | awk -F/ '{print $3}'))"
            elif read_preview_meta "$name" 2>/dev/null && [[ -s "$(notify_site_url_path "$PREVIEW_PROJECT")" ]]; then
                log_info "'$name': no URL of its own — uses its parent '$PREVIEW_PROJECT's"
            else
                log_info "'$name': no URL of its own"
            fi
            if [[ -n "${NOTIFY_WEBHOOK:-}" ]]; then
                log_info "server-wide NOTIFY_WEBHOOK is set — also gets this site's events"
            fi
            log_info "events sent: ${NOTIFY_EVENTS:-$NOTIFY_EVENTS_DEFAULT}"
            ;;
        test)
            local -a urls=()
            mapfile -t urls < <(notify_urls "$name")
            [[ "${#urls[@]}" -gt 0 ]] || die "notify: no URL to send to${name:+ for '$name'} (set NOTIFY_WEBHOOK, or 'notify <name> --set-url')"
            local url sent=0
            for url in "${urls[@]}"; do
                if notify_post "$url" info "ddeploy test message${name:+ for $name}" "If you can read this, notifications from ${BASE_DOMAIN} work." test "$name"; then
                    sent=$((sent + 1))
                else
                    log_warn "notify: POST failed to one URL (host: $(awk -F/ '{print $3}' <<< "$url"))"
                fi
            done
            [[ "$sent" -eq "${#urls[@]}" ]] || die "notify: $sent of ${#urls[@]} test message(s) delivered"
            log_info "sent $sent test message(s)"
            ;;
    esac
}
