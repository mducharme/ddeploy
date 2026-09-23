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

# Ubuntu 24.04 ships needrestart, which hooks apt/dpkg and, left in its
# default interactive mode, can ask "which services should be
# restarted?" on an apt-get install that touches a running service
# (mariadb-server, nginx, php-fpm all qualify). This alone did NOT stop
# the actual hang confirmed in testing (cmd_init.sh has the real fix —
# closing stdin) but it's a legitimate, harmless belt-and-suspenders: if
# something in this tool's apt-get sequence ever runs without stdin
# closed, this still keeps needrestart itself from being the thing that
# blocks.
export NEEDRESTART_MODE=a

# Every backup-uploads/backup-database run (cron or by hand) invokes
# rclone once per site — without this, each call prints a benign
# 'Config file "~/.config/rclone/rclone.conf" not found - using
# defaults' NOTICE (confirmed in production: pure noise on a fleet with
# more than a couple of sites, drowning out anything that actually
# matters). Deliberate: this tool always builds an inline, config-file-
# free remote spec (backup_remote_spec in lib/backup.sh) — there was
# never meant to be an rclone.conf to find. RCLONE_QUIET only drops
# NOTICE-and-below; confirmed a real ERROR (bad credentials, unreachable
# endpoint) still prints and the exit code is untouched.
export RCLONE_QUIET=true

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
    [[ -f "$conf" ]] || die "missing $conf — run './provision.sh configure' first (or './install.sh')"
    # shellcheck source=/dev/null
    source "$conf"
    : "${BASE_DOMAIN:?provisioner.conf: BASE_DOMAIN not set}"
    : "${SITES_ROOT:?provisioner.conf: SITES_ROOT not set}"
    : "${CF_CREDENTIALS:?provisioner.conf: CF_CREDENTIALS not set}"
    : "${CERT_EMAIL:?provisioner.conf: CERT_EMAIL not set}"
    : "${BASELINE_PHP:?provisioner.conf: BASELINE_PHP not set}"
    : "${DEFAULT_PHP:?provisioner.conf: DEFAULT_PHP not set}"
    : "${GIT_DEPLOY_KEY:?provisioner.conf: GIT_DEPLOY_KEY not set}"
    PERSISTENT_ROOT="${PERSISTENT_ROOT:-/home/deploy/persistent}"
    BASIC_AUTH_DEFAULT="${BASIC_AUTH_DEFAULT:-false}"
    BASIC_AUTH_CREDENTIALS="${BASIC_AUTH_CREDENTIALS:-/etc/nginx/htpasswd/default}"
    CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-64m}"
    FPM_MAX_CHILDREN="${FPM_MAX_CHILDREN:-5}"
    PHP_EXTENSIONS="${PHP_EXTENSIONS:-cli mysql mbstring xml curl zip gd}"
    CLOUDFLARE_PROXIED="${CLOUDFLARE_PROXIED:-true}"
    DB_HOST="${DB_HOST:-127.0.0.1}"
    DB_ADMIN_CREDENTIALS="${DB_ADMIN_CREDENTIALS:-}"
    DB_GRANT_HOST="${DB_GRANT_HOST:-localhost}"
    validate_db_grant_host "$DB_GRANT_HOST"
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
    WEBHOOK_ENABLED="${WEBHOOK_ENABLED:-false}"
    WEBHOOK_HOSTNAME="${WEBHOOK_HOSTNAME:-hooks.$BASE_DOMAIN}"
    WEBHOOK_SECRET="${WEBHOOK_SECRET:-/etc/ddeploy/webhook.secret}"
    WEBHOOK_SECRET_BITBUCKET="${WEBHOOK_SECRET_BITBUCKET:-}"
    WEBHOOK_LISTEN="${WEBHOOK_LISTEN:-127.0.0.1:8787}"
    NOTIFY_WEBHOOK="${NOTIFY_WEBHOOK:-}"
    NOTIFY_COOLDOWN="${NOTIFY_COOLDOWN:-3600}"
    PREVIEW_COMMENT_CREDENTIALS="${PREVIEW_COMMENT_CREDENTIALS:-}"
    RELEASES_KEEP="${RELEASES_KEEP:-5}"
}

# Lighter loader for `init-db`, run on a dedicated database server that
# doesn't need any of the web-server config load_conf requires.
load_db_conf() {
    local conf="$PROVISIONER_DIR/provisioner.conf"
    [[ -f "$conf" ]] || die "missing $conf — run './provision.sh configure' first (or './install.sh')"
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

# Wrapper directory: Linux user HOME, .ssh, releases/, current.
# Previews have no current symlink, so this is also their checkout.
site_root() { echo "$SITES_ROOT/$1"; }

# Live code directory: .../<name>/current for atomic sites, the wrapper
# itself for previews and not-yet-migrated checkouts.
site_dir() {
    local root="$SITES_ROOT/$1"
    if [[ -L "$root/current" ]]; then
        echo "$root/current"
    else
        echo "$root"
    fi
}

# Optional CONFIG_CHECKOUT_DIR: parse_config / resolve_config_path read
# the NEW release's YAML before `current` is swapped. Callers unset it.
config_checkout_dir() {
    local name="$1"
    if [[ -n "${CONFIG_CHECKOUT_DIR:-}" ]]; then
        echo "$CONFIG_CHECKOUT_DIR"
    else
        site_dir "$name"
    fi
}

is_releases_layout() { [[ -L "$(site_root "$1")/current" ]]; }

current_release_real() {
    readlink -f "$(site_root "$1")/current" 2>/dev/null || true
}

# git (2.35.2+, which Ubuntu 24.04 ships) refuses to operate in a
# repository it doesn't own. Every site directory ends up owned by its
# own www-<name> (apply_permissions), but a few read-only git calls
# (deploy's/deploy-preview's SHA for logging, list's SHA/date columns,
# provision-preview inferring a repo-url from the parent) run as root —
# root is already fully trusted here (it's this tool's own operator), so
# register each site's directory as an exception. safe.directory has no
# wildcard/prefix form (confirmed: "safe.directory = $SITES_ROOT/*" is
# NOT a glob and matches nothing) — has to be the literal path, one entry
# per site, hence this being called per-directory at provision time
# rather than once for the whole SITES_ROOT in `init`.
git_trust_repo() {
    local dir="$1"
    local p
    for p in "$dir" "$dir/.git"; do
        [[ -e "$p" ]] || continue
        git config --system --get-all safe.directory 2>/dev/null | grep -qxF "$p" \
            || git config --system --add safe.directory "$p"
    done
}

# Grants traversal (o+x) on every ancestor directory from $1 up to (but
# not including) / that's missing it. nginx/php-fpm run as www-data and
# need to stat/traverse the FULL path down to a site's docroot — including
# every directory above it, not just ones this tool itself owns. This
# matters because SITES_ROOT commonly lives inside another user's home
# directory (the documented default is /home/deploy/sites), and Ubuntu
# creates new home directories as 750 by default — without this, every
# single site 404s with "Permission denied" in nginx's error log, no
# matter how correctly the site's own directory is permissioned
# (confirmed against a real Ubuntu 24.04 useradd --create-home).
ensure_traversable() {
    local dir="$1" p mode last_digit
    p="$(cd "$dir" 2>/dev/null && pwd)" || return 0
    while [[ "$p" != "/" ]]; do
        mode="$(stat -c '%a' "$p" 2>/dev/null)"
        last_digit="${mode: -1}"
        case "$last_digit" in
            1|3|5|7) ;;  # other already has execute
            *)
                chmod o+x "$p"
                log_info "granted traversal (o+x) on $p — nginx/php-fpm run as www-data and need to reach $dir regardless of who owns directories above it"
                ;;
        esac
        p="$(dirname "$p")"
    done
}

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
