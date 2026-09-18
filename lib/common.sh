#!/usr/bin/env bash
# Shared helpers: config loading, logging, validation, template rendering.
# Sourced by provision.sh; never executed directly.

# Site name charset: used as a filesystem path segment, Linux username
# suffix, and DB identifier. Capped at 28 chars so "www-<name>" (the
# Linux username) stays within the 32-char limit.
NAME_RE='^[a-z0-9][a-z0-9-]{0,27}$'

PROVISIONER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$PROVISIONER_DIR/logs"
GENERATED_DIR="$PROVISIONER_DIR/generated"

log_info()  { printf '\033[36m[info]\033[0m  %s\n' "$*" >&2; }
log_warn()  { printf '\033[33m[warn]\033[0m  %s\n' "$*" >&2; }
log_error() { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# Appends a timestamped line to a site's provision/deploy log.
site_log() {
    local name="$1" msg="$2"
    mkdir -p "$LOG_DIR"
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$LOG_DIR/$name.log"
}

load_conf() {
    local conf="$PROVISIONER_DIR/provisioner.conf"
    [[ -f "$conf" ]] || die "missing $conf"
    # shellcheck source=/dev/null
    source "$conf"
    : "${BASE_DOMAIN:?provisioner.conf: BASE_DOMAIN not set}"
    : "${SITES_ROOT:?provisioner.conf: SITES_ROOT not set}"
    : "${CF_CREDENTIALS:?provisioner.conf: CF_CREDENTIALS not set}"
    : "${CERT_EMAIL:?provisioner.conf: CERT_EMAIL not set}"
    : "${BASELINE_PHP:?provisioner.conf: BASELINE_PHP not set}"
    : "${DEFAULT_PHP:?provisioner.conf: DEFAULT_PHP not set}"
    : "${GIT_DEPLOY_KEY:?provisioner.conf: GIT_DEPLOY_KEY not set}"
    BASIC_AUTH_DEFAULT="${BASIC_AUTH_DEFAULT:-false}"
    BASIC_AUTH_CREDENTIALS="${BASIC_AUTH_CREDENTIALS:-/etc/nginx/htpasswd/default}"
    PHP_EXTENSIONS="${PHP_EXTENSIONS:-cli mysql mbstring xml curl zip gd}"
    CLOUDFLARE_PROXIED="${CLOUDFLARE_PROXIED:-true}"
    DB_HOST="${DB_HOST:-127.0.0.1}"
    DB_ADMIN_CREDENTIALS="${DB_ADMIN_CREDENTIALS:-}"
    DB_GRANT_HOST="${DB_GRANT_HOST:-localhost}"
    BACKUP_ENABLED="${BACKUP_ENABLED:-false}"
    BACKUP_CREDENTIALS="${BACKUP_CREDENTIALS:-}"
    BACKUP_BUCKET="${BACKUP_BUCKET:-}"
    BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-17 * * * *}"
    DB_BACKUP_ENABLED="${DB_BACKUP_ENABLED:-false}"
    DB_BACKUP_SCHEDULE="${DB_BACKUP_SCHEDULE:-23 * * * *}"
    DB_BACKUP_RETENTION_DAYS="${DB_BACKUP_RETENTION_DAYS:-7}"
    PREVIEW_DB_MODE="${PREVIEW_DB_MODE:-shared}"
    PREVIEW_SEED="${PREVIEW_SEED:-true}"
    PREVIEW_PRUNE_ENABLED="${PREVIEW_PRUNE_ENABLED:-false}"
    PREVIEW_PRUNE_SCHEDULE="${PREVIEW_PRUNE_SCHEDULE:-37 3 * * *}"
}

# Lighter loader for `init-db`, run on a dedicated database server that
# doesn't need any of the web-server config load_conf requires.
load_db_conf() {
    local conf="$PROVISIONER_DIR/provisioner.conf"
    [[ -f "$conf" ]] || die "missing $conf"
    # shellcheck source=/dev/null
    source "$conf"
    : "${DB_ADMIN_CREDENTIALS:?provisioner.conf: DB_ADMIN_CREDENTIALS not set}"
    : "${DB_ALLOWED_HOSTS:?provisioner.conf: DB_ALLOWED_HOSTS not set}"
}

# Whether $1 has a live vhost — the simplest reliable signal that
# `provision` has actually completed for it (not just cloned/configured).
is_provisioned() { [[ -f "/etc/nginx/sites-available/$1.conf" ]]; }

validate_name() {
    local name="$1"
    [[ "$name" =~ $NAME_RE ]] || die "invalid site name '$name' (must match $NAME_RE)"
}

require_root() {
    [[ "$EUID" -eq 0 ]] || die "this command must be run as root (use sudo)"
}

# Prints the port(s) sshd is actually configured to listen on (usually
# just 22, but not always — hardcoding 22 in a firewall rule risks
# locking out a server using a non-standard SSH port the moment ufw's
# default-deny takes effect). `sshd -T` prints the fully-resolved
# effective config (Include directives, defaults, and all), so it's used
# over grepping sshd_config directly; falls back to 22 if sshd isn't
# found or its config can't be parsed for some reason.
detect_ssh_ports() {
    local ports
    ports="$(sshd -T 2>/dev/null | awk 'tolower($1)=="port"{print $2}' | sort -u)"
    [[ -z "$ports" ]] && ports="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | sort -u)"
    echo "${ports:-22}"
}

# Confirms the Go (mikefarah) yq is on PATH, not the Python (kislyuk) one
# — same binary name, incompatible CLI.
require_yq() {
    command -v yq >/dev/null 2>&1 || die "yq not found — run 'init' first, or install the Go yq (mikefarah/yq)"
    if ! yq --version 2>&1 | grep -qi 'mikefarah'; then
        die "found a 'yq' on PATH but it isn't the Go (mikefarah) build — this tool needs that one, not the Python yq"
    fi
}

site_dir() { echo "$SITES_ROOT/$1"; }

# Simple, safe {{KEY}} -> value substitution (literal, not regex) — avoids
# sed delimiter collisions when values contain '/', '.', etc.
render_template() {
    local tmpl="$1" out="$2"; shift 2
    local content
    content="$(cat "$tmpl")"
    local kv key val
    for kv in "$@"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        content="${content//"{{$key}}"/$val}"
    done
    printf '%s\n' "$content" > "$out"
}

# Idempotent upsert of KEY=value in a .env file.
write_env_var() {
    local env_file="$1" key="$2" val="$3"
    touch "$env_file"
    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        local tmp; tmp="$(mktemp)"
        awk -v k="$key" -v v="$val" -F'=' 'BEGIN{OFS="="} $1==k{$0=k"="v} {print}' "$env_file" > "$tmp"
        mv "$tmp" "$env_file"
    else
        printf '%s=%s\n' "$key" "$val" >> "$env_file"
    fi
}

read_env_var() {
    local env_file="$1" key="$2"
    [[ -f "$env_file" ]] || return 1
    grep "^${key}=" "$env_file" | head -n1 | cut -d= -f2-
}
