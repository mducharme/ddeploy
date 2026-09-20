#!/usr/bin/env bash
# Failure paging: one POST to NOTIFY_WEBHOOK when an unattended command
# fails. Empty URL is a no-op. Never called on success. The webhook URL
# is a credential — this file must not log it.

NOTIFY_STATE_DIR="/var/lib/ddeploy/notify"
NOTIFY_COOLDOWN_DEFAULT=3600

# $1 command  $2 site (optional)  $3 detail (optional)
# Always returns 0 — a dead Slack URL must not fail the job that paged.
notify_failure() {
    local command="$1" site="${2:-}" detail="${3:-}"
    [[ -n "${NOTIFY_WEBHOOK:-}" ]] || return 0
    [[ -n "$command" ]] || return 0

    local cooldown="${NOTIFY_COOLDOWN:-$NOTIFY_COOLDOWN_DEFAULT}"
    [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown="$NOTIFY_COOLDOWN_DEFAULT"

    local key
    key="$(printf '%s_%s' "$command" "$site" | tr -c 'A-Za-z0-9._-' '_')"
    mkdir -p "$NOTIFY_STATE_DIR"
    chmod 700 "$NOTIFY_STATE_DIR" 2>/dev/null || true
    local stamp="$NOTIFY_STATE_DIR/$key"
    if [[ "$cooldown" -gt 0 && -f "$stamp" ]]; then
        local now mtime age
        now="$(date +%s)"
        mtime="$(stat -c %Y "$stamp" 2>/dev/null || echo 0)"
        age=$((now - mtime))
        if [[ "$age" -ge 0 && "$age" -lt "$cooldown" ]]; then
            log_info "notify: skipping '$command'${site:+ $site} — last sent ${age}s ago (cooldown ${cooldown}s)"
            return 0
        fi
    fi

    # Discord content is capped at 2000; keep well under that.
    if [[ "${#detail}" -gt 800 ]]; then
        detail="${detail:0:800}..."
    fi

    local host="${BASE_DOMAIN:-unknown}"
    local text="ddeploy ${command} failed on ${host}"
    [[ -n "$site" ]] && text+=" (${site})"
    [[ -n "$detail" ]] && text+=": ${detail}"

    if ! DDEPLOY_NOTIFY_URL="$NOTIFY_WEBHOOK" \
        DDEPLOY_NOTIFY_TEXT="$text" \
        DDEPLOY_NOTIFY_HOST="$host" \
        DDEPLOY_NOTIFY_CMD="$command" \
        DDEPLOY_NOTIFY_SITE="$site" \
        DDEPLOY_NOTIFY_DETAIL="$detail" \
        python3 -c '
import json, os, sys, urllib.error, urllib.request
url = os.environ.get("DDEPLOY_NOTIFY_URL", "")
if not url:
    sys.exit(1)
payload = {
    "text": os.environ.get("DDEPLOY_NOTIFY_TEXT", ""),
    "content": os.environ.get("DDEPLOY_NOTIFY_TEXT", ""),
    "host": os.environ.get("DDEPLOY_NOTIFY_HOST", ""),
    "command": os.environ.get("DDEPLOY_NOTIFY_CMD", ""),
    "site": os.environ.get("DDEPLOY_NOTIFY_SITE", ""),
    "detail": os.environ.get("DDEPLOY_NOTIFY_DETAIL", ""),
}
req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json", "User-Agent": "ddeploy-notify"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=8) as resp:
        if getattr(resp, "status", 200) >= 400:
            sys.exit(1)
except (urllib.error.URLError, TimeoutError, ValueError, OSError):
    sys.exit(1)
' >/dev/null 2>&1; then
        log_warn "notify: POST failed for '$command'${site:+ $site} — check NOTIFY_WEBHOOK (URL is not logged)"
        return 0
    fi
    date +%s > "$stamp"
    chmod 600 "$stamp" 2>/dev/null || true
    return 0
}

# Last lines of a log file, flattened, for the detail field.
notify_log_snippet() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    tail -n 8 "$file" 2>/dev/null | tr '\n' ' ' | cut -c1-400 || true
}
