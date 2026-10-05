#!/usr/bin/env bash
# Shared helpers: config loading, logging, validation, template rendering.
# Sourced by provision.sh; never executed directly.

# Site name charset: used as a filesystem path segment, Linux username
# suffix, and DB identifier. Capped at 28 chars so "www-<name>" (the
# Linux username) stays within the 32-char limit.
NAME_RE='^[a-z0-9][a-z0-9-]{0,27}$'

PROVISIONER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The checkout is code only; everything per-server lives in the
# standard places, so it can be moved or re-cloned without losing
# anything:
#   CONF_FILE, MANIFEST_FILE  /etc/ddeploy/                configuration
#   GENERATED_DIR             /var/lib/ddeploy/generated   per-site state
#                             (sidecars, overrides, preview metadata, deploy
#                             SHAs, worker scripts, *.dbpass, *.notify-url)
#   LOG_DIR                   /var/log/ddeploy/            site/fleet/webhook logs
DDEPLOY_ETC="/etc/ddeploy"
DDEPLOY_STATE="/var/lib/ddeploy"
CONF_FILE="$DDEPLOY_ETC/provisioner.conf"
MANIFEST_FILE="$DDEPLOY_ETC/manifest"
GENERATED_DIR="$DDEPLOY_STATE/generated"
LOG_DIR="/var/log/ddeploy"

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
# rclone once per site — RCLONE_QUIET only drops NOTICE-and-below;
# confirmed a real ERROR (bad credentials, unreachable endpoint) still
# prints and the exit code is untouched.
export RCLONE_QUIET=true

# backup_remote_spec (lib/backup.sh) writes BACKUP_CREDENTIALS'
# access_key_id/secret_access_key into a real rclone config file here
# (mode 600, regenerated fresh on every call) instead of putting them
# directly on rclone's own argv via an inline `:s3,access_key_id=...:`
# connection string — an older version of this tool did exactly that,
# which put both secrets in `ps aux` output (visible to any user who can
# see process listings, for the whole duration of every backup/restore/
# list call) rather than just this one root-only file. Set globally,
# not per-call, so every rclone invocation anywhere in this tool picks
# it up automatically — see backup_remote_spec for why nothing else
# needs to change.
export RCLONE_CONFIG="/etc/ddeploy/rclone-backup.conf"

# Every line ddeploy logs — on the terminal or in a file under $LOG_DIR —
# starts with one of four tags, padded so the messages line up:
#   [info]  what's happening    [ok]    something finished fine
#   [warn]  needs a look        [error] something failed
# In files, after a UTC timestamp: "2026-10-04T21:00:11Z [ok]    deploy:
# done at ..." (log_line). webddeploy's log view colors the tag.
# Sets LOG_TAG for level $1 (anything unknown is info).
log_tag() {
    case "$1" in
        ok)    LOG_TAG='[ok]   ' ;;
        warn)  LOG_TAG='[warn] ' ;;
        error) LOG_TAG='[error]' ;;
        *)     LOG_TAG='[info] ' ;;
    esac
}

# To stderr. Colored only when stderr is a terminal (and NO_COLOR is
# unset) — not escape codes in cron mail, the journal, or captured logs.
# LOG_TIMESTAMPS=1 prefixes a UTC timestamp, same format as the files
# (see log_timestamps_unless_tty). Builtins only, no subshells: these
# run for every line of every command.
_log() {
    local level="$1" color="$2" msg="$3" ts="" c="" r=""
    [[ "${LOG_TIMESTAMPS:-0}" == "1" ]] && TZ=UTC printf -v ts '%(%Y-%m-%dT%H:%M:%SZ)T ' -1
    [[ -t 2 && -z "${NO_COLOR:-}" ]] && { c=$'\033['"$color"'m'; r=$'\033[0m'; }
    log_tag "$level"
    printf '%s%s%s%s %s\n' "$ts" "$c" "$LOG_TAG" "$r" "$msg" >&2
}
log_info()  { _log info 36 "$*"; }
log_ok()    { _log ok 32 "$*"; }
log_warn()  { _log warn 33 "$*"; }
log_error() { _log error 31 "$*"; }

# Appends one line to log file $1: UTC timestamp, the tag for level $2
# (info|ok|warn|error), message $3. Every ddeploy-written log line goes
# through here; only output quoted from other programs (a failed step's
# last lines, indented "    | " under the line that says what failed)
# isn't tagged.
log_line() {
    local file="$1" level="$2" msg="$3" ts
    TZ=UTC printf -v ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1
    log_tag "$level"
    mkdir -p "${file%/*}"
    printf '%s %s %s\n' "$ts" "$LOG_TAG" "$msg" >> "$file"
}

# For commands cron runs into an append-only log ($LOG_DIR/<job>.log):
# timestamp every log line when not on a terminal, so one run can be
# told from the next. Done here rather than in the cron.d line so
# existing installs get it without re-running init.
log_timestamps_unless_tty() {
    [[ -t 2 ]] || LOG_TIMESTAMPS=1
}
die()       { log_error "$*"; exit 1; }

# Appends a tagged, timestamped line to a site's log ($LOG_DIR/<name>.log).
# $3: info (default), ok, warn or error.
site_log() {
    log_line "$LOG_DIR/$1.log" "${3:-info}" "$2"
}

# Runs "$@" with its output (stdout and stderr together) shown live on
# stderr and copied to file $1; returns the command's own exit code, not
# tee's. Always call it as `run_captured "$f" cmd ... || handle_failure`:
# the || is what stops set -e from exiting before the return. stderr,
# not stdout, so it's safe inside a function whose stdout is captured
# (prepare_forward_release prints the new release path).
run_captured() {
    local out="$1"; shift
    "$@" 2>&1 | tee "$out" >&2
    return "${PIPESTATUS[0]}"
}

# The site log only gets a command's output when it failed: the last
# lines of captured output $2, indented under the line saying what
# failed, so `ddeploy logs <name>` shows why and not just that. Progress
# bars (carriage returns), color codes and blank lines are dropped.
site_log_output() {
    local name="$1" file="$2" lines="${3:-25}"
    [[ -s "$file" ]] || return 0
    mkdir -p "$LOG_DIR"
    tr '\r' '\n' < "$file" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | grep -v '^[[:space:]]*$' \
        | tail -n "$lines" | cut -c1-300 | sed 's/^/    | /' >> "$LOG_DIR/$name.log" || true
}

load_conf() {
    local conf="$CONF_FILE"
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
    # The bucket belongs with the endpoint and keys: BACKUP_BUCKET in the
    # BACKUP_CREDENTIALS file wins; provisioner.conf's is the fallback
    # (older setups). Read in a subshell: the keys don't land in this one.
    BACKUP_BUCKET_CONF="$BACKUP_BUCKET"
    if [[ -n "$BACKUP_CREDENTIALS" && -r "$BACKUP_CREDENTIALS" ]]; then
        local bucket_from_creds
        # shellcheck source=/dev/null
        bucket_from_creds="$(unset BACKUP_BUCKET; source "$BACKUP_CREDENTIALS" >/dev/null 2>&1; printf '%s' "${BACKUP_BUCKET:-}")"
        [[ -n "$bucket_from_creds" ]] && BACKUP_BUCKET="$bucket_from_creds"
    fi
    BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-17 * * * *}"
    DB_BACKUP_ENABLED="${DB_BACKUP_ENABLED:-false}"
    DB_BACKUP_SCHEDULE="${DB_BACKUP_SCHEDULE:-23 * * * *}"
    DB_BACKUP_RETENTION_DAYS="${DB_BACKUP_RETENTION_DAYS:-7}"
    PREVIEW_DB_MODE="${PREVIEW_DB_MODE:-shared}"
    PREVIEW_SEED="${PREVIEW_SEED:-true}"
    PREVIEW_BRANCHES="${PREVIEW_BRANCHES:-}"
    PREVIEW_PRUNE_ENABLED="${PREVIEW_PRUNE_ENABLED:-false}"
    PREVIEW_PRUNE_SCHEDULE="${PREVIEW_PRUNE_SCHEDULE:-37 3 * * *}"
    DOCTOR_SCHEDULE="${DOCTOR_SCHEDULE:-*/10 * * * *}"
    WEBHOOK_ENABLED="${WEBHOOK_ENABLED:-false}"
    WEBHOOK_HOSTNAME="${WEBHOOK_HOSTNAME:-hooks.$BASE_DOMAIN}"
    WEBHOOK_SECRET="${WEBHOOK_SECRET:-/etc/ddeploy/webhook.secret}"
    WEBHOOK_SECRET_BITBUCKET="${WEBHOOK_SECRET_BITBUCKET:-}"
    WEBHOOK_LISTEN="${WEBHOOK_LISTEN:-127.0.0.1:8787}"
    WEB_ENABLED="${WEB_ENABLED:-false}"
    WEB_HOSTNAME="${WEB_HOSTNAME:-ddeploy.$BASE_DOMAIN}"
    WEB_LISTEN="${WEB_LISTEN:-127.0.0.1:8790}"
    WEB_USER="${WEB_USER:-ddeploy-web}"
    RUN_LOG_RETENTION_DAYS="${RUN_LOG_RETENTION_DAYS:-30}"
    WEB_IMPORT_MAX_MB="${WEB_IMPORT_MAX_MB:-2048}"
    DB_SNAPSHOT_KEEP="${DB_SNAPSHOT_KEEP:-5}"
    WEB_UPLOAD_MAX_MB="${WEB_UPLOAD_MAX_MB:-10240}"
    UPLOADS_SNAPSHOT_KEEP="${UPLOADS_SNAPSHOT_KEEP:-3}"
    UPLOADS_BACKUP_VERSIONS_DAYS="${UPLOADS_BACKUP_VERSIONS_DAYS:-30}"
    NOTIFY_WEBHOOK="${NOTIFY_WEBHOOK:-}"
    NOTIFY_COOLDOWN="${NOTIFY_COOLDOWN:-3600}"
    NOTIFY_EVENTS="${NOTIFY_EVENTS:-deploy-success deploy-failure preview-created preview-removed webhook-rejected}"
    PREVIEW_COMMENT_CREDENTIALS="${PREVIEW_COMMENT_CREDENTIALS:-}"
    RELEASES_KEEP="${RELEASES_KEEP:-5}"
    ALLOW_FORCE_PUSH="${ALLOW_FORCE_PUSH:-false}"
    NODE_ENABLED="${NODE_ENABLED:-true}"
    NVM_ROOT="${NVM_ROOT:-/opt/nvm}"
    BASELINE_NODE="${BASELINE_NODE:-22}"
    DEFAULT_NODE="${DEFAULT_NODE:-22}"
    NODE_BUILD_TIMEOUT="${NODE_BUILD_TIMEOUT:-1200}"
    NODE_BUILD_MEMORY_MAX="${NODE_BUILD_MEMORY_MAX:-2G}"
    NODE_REUSE_MODULES="${NODE_REUSE_MODULES:-true}"
    validate_bool "$NODE_ENABLED" "NODE_ENABLED"
    validate_bool "$NODE_REUSE_MODULES" "NODE_REUSE_MODULES"
    [[ "$NVM_ROOT" == /* && "$NVM_ROOT" != "/" ]] || die "provisioner.conf: NVM_ROOT must be an absolute path"
    validate_node_version_spec "$DEFAULT_NODE" "provisioner.conf: DEFAULT_NODE"
    local spec
    for spec in $BASELINE_NODE; do validate_node_version_spec "$spec" "provisioner.conf: BASELINE_NODE entry"; done
    [[ "$NODE_BUILD_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "provisioner.conf: NODE_BUILD_TIMEOUT must be a positive number of seconds"
    [[ -z "$NODE_BUILD_MEMORY_MAX" || "$NODE_BUILD_MEMORY_MAX" =~ ^[1-9][0-9]*[KMG]?$ ]] \
        || die "provisioner.conf: NODE_BUILD_MEMORY_MAX must look like 2G / 1536M (or be empty for no cap)"
}

# Lighter loader for `init-db`, run on a dedicated database server that
# doesn't need any of the web-server config load_conf requires.
load_db_conf() {
    local conf="$CONF_FILE"
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
# — same binary name, incompatible CLI. Once per process (YQ_CHECKED is
# inherited by subshells, so call it before fanning out).
require_yq() {
    [[ -n "${YQ_CHECKED:-}" ]] && return 0
    command -v yq >/dev/null 2>&1 || die "yq not found — run 'init' first, or install the Go yq (mikefarah/yq)"
    if ! yq --version 2>&1 | grep -qi 'mikefarah'; then
        die "found a 'yq' on PATH but it isn't the Go (mikefarah) build — this tool needs that one, not the Python yq"
    fi
    YQ_CHECKED=1
}

# --- yqc: `yq eval EXPR FILE`, batched ----------------------------------
# Reading one site's config used to start a yq process per field (~40).
# yqc evaluates every expression in YQC_EXPRS against a file in ONE yq
# run, the first time that file is asked about, and answers from memory
# after that. The output is byte-for-byte what `yq eval EXPR FILE`
# prints (tests/unit.sh checks every expression). Anything else falls
# through to a real yq call, so an expression missing from the list is
# only slower, never wrong.
#
# Freshness: each call re-reads the file (the `read` builtin, no
# process) and reloads if its content changed, so a write in between —
# override, generated sidecars, `yq -i` anywhere — is never missed.
# A file yq can't parse isn't cached: every call then goes to real yq,
# with real yq's errors.
YQC_EXPRS=(
    '.name' '.php_version' '.docroot // ""' '.webserver_type' '.upload_dirs[]'
    '.database.name // ""' '.database.user // ""'
    '.additional_fqdns[]' '.additional_hostnames[]' '.auth_exempt_paths[]'
    '.backup_exclude[]' '.persistent_files[]' '.queue_workers[]' '.deny_php_paths[]'
    '.basic_auth // ""' '.client_max_body_size // ""' '.composer_dev // ""'
    '.db_backup_retention_days // ""' '.db_env_scheme // ""' '.deny_php_in_uploads // ""'
    '.fpm_max_children // ""' '.nodejs_version // ""' '.security_headers // ""' '.static_cache // ""'
    '.build' '.build | tag' '.build.path // ""' '.build.package_manager // "auto"'
    '.build.install' '.build.keep_node_modules' '.build.script // ""' '.build.command // ""'
    '(.build.env // {}) | to_entries | .[] | .key + "=" + (.value | tostring)'
    '.build.outputs[]'
    '(.php_ini // {}) | to_entries | .[] | .key + "=" + (.value | tostring)'
    '.redirects | tag' '.redirects | length' '.schedule | tag' '.schedule | length'
    '.hooks | has("post-start")' '.hooks."post-start" | length'
)
declare -gA YQC_IDX=() YQC_FILE_ID=() YQC_CONTENT=() YQC_VAL=() YQC_HAS=()
YQC_MARK="@@yqc-$$-$RANDOM$RANDOM"
YQC_NEXT_ID=0
for _yqc_i in "${!YQC_EXPRS[@]}"; do YQC_IDX["${YQC_EXPRS[_yqc_i]}"]="$_yqc_i"; done
unset _yqc_i

yqc() {
    local expr="$1" file="$2"
    local idx="${YQC_IDX[$expr]-}"
    if [[ -z "$idx" || ! -f "$file" || ! -r "$file" ]]; then
        yq eval "$expr" "$file"
        return
    fi
    local content=""
    IFS= read -r -d '' content < "$file" || true
    if [[ -z "${YQC_CONTENT[$file]+x}" || "${YQC_CONTENT[$file]}" != "$content" ]]; then
        yqc_load "$file" "$content"
    fi
    local id="${YQC_FILE_ID[$file]}"
    if [[ "$id" == "x" ]]; then
        yq eval "$expr" "$file"
        return
    fi
    [[ "${YQC_HAS[$id:$idx]}" == 1 ]] && printf '%s\n' "${YQC_VAL[$id:$idx]}"
    return 0
}

# Loads files "$@" into the cache in THIS shell. Callers read values via
# $(yqc ...) or < <(yqc ...) — subshells, whose own loads would be thrown
# away — so prime first and let those subshells inherit the cache.
yqc_prime() {
    local f content
    for f in "$@"; do
        [[ -n "$f" && -f "$f" && -r "$f" ]] || continue
        content=""
        IFS= read -r -d '' content < "$f" || true
        [[ -n "${YQC_CONTENT[$f]+x}" && "${YQC_CONTENT[$f]}" == "$content" ]] || yqc_load "$f" "$content"
    done
    return 0
}

# One yq run printing every YQC_EXPRS result after its own marker line,
# split back into YQC_VAL/YQC_HAS (whether it printed anything at all —
# an empty string prints an empty line, an empty stream nothing).
#
# Each expression gets its own copy of the file (the file is passed once
# per expression, eval-all + select(fileIndex)): reading a missing path
# in yq adds it to the document in memory, so in one shared document
# `.build.install` would make a later `.build` print keys that aren't in
# the file. -N: no `---` between documents.
#
# Only a file whose top level is a map is cached (every real config is):
# for an empty or comments-only file, eval-all prints nothing where a
# lone `yq eval` prints "null", so those go to real yq. The first output
# line is that check, the document's tag.
yqc_load() {
    local file="$1" content="$2"
    YQC_CONTENT["$file"]="$content"
    local batch="(select(fileIndex == 0) | tag)" i
    local -a files=("$file")
    for i in "${!YQC_EXPRS[@]}"; do
        batch+=", (select(fileIndex == $((i + 1))) | (\"$YQC_MARK $i\", (${YQC_EXPRS[i]})))"
        files+=("$file")
    done
    local out
    if ! out="$(yq eval-all -N "$batch" "${files[@]}" 2>/dev/null)" || [[ "${out%%$'\n'*}" != '!!map' ]]; then
        YQC_FILE_ID["$file"]="x"
        return 0
    fi
    out="${out#*$'\n'}"$'\n'"$YQC_MARK end"
    local id="${YQC_FILE_ID[$file]-}"
    if [[ -z "$id" || "$id" == "x" ]]; then
        id="$YQC_NEXT_ID"
        YQC_NEXT_ID=$((YQC_NEXT_ID + 1))
        YQC_FILE_ID["$file"]="$id"
    fi
    local line cur=""
    while IFS= read -r line; do
        if [[ "$line" == "$YQC_MARK "* ]]; then
            cur="${line#"$YQC_MARK "}"
            [[ "$cur" == end ]] && break
            YQC_VAL["$id:$cur"]=""
            YQC_HAS["$id:$cur"]=0
        elif [[ -n "$cur" ]]; then
            if [[ "${YQC_HAS[$id:$cur]}" == 1 ]]; then
                YQC_VAL["$id:$cur"]+=$'\n'"$line"
            else
                YQC_VAL["$id:$cur"]="$line"
                YQC_HAS["$id:$cur"]=1
            fi
        fi
    done <<< "$out"
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

# Prints the first directory above the checkout that a non-root user
# owns or can write to, or nothing. Root runs code from the checkout
# (cron, the webhook worker); whoever can write to a parent can rename
# the checkout away and put their own in its place (docs/security.md).
checkout_unsafe_parent() {
    local p="$PROVISIONER_DIR"
    while [[ "$p" != "/" ]]; do
        p="$(dirname "$p")"
        if [[ "$(stat -c %u "$p" 2>/dev/null)" != "0" ]] || [[ -n "$(find "$p" -maxdepth 0 -perm /022 2>/dev/null)" ]]; then
            printf '%s' "$p"
            return 0
        fi
    done
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

# Idempotent upsert of KEY=value in a .env file. Rewrites the file in
# place (`cat tmp > file`, never `mv tmp file`): a site's .env is usually
# a symlink into PERSISTENT_ROOT, and an mv would replace that symlink
# with a plain file in the release — the persistent copy would silently
# stop being the one PHP reads, until the next deploy re-linked it and
# threw the edit away. In-place also keeps the file's owner and mode.
# Values go through ENVIRON, not awk -v, which would expand backslash
# escapes inside them.
write_env_var() {
    local env_file="$1" key="$2" val="$3"
    touch "$env_file"
    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        local tmp; tmp="$(mktemp)"
        K="$key" V="$val" awk 'BEGIN{k=ENVIRON["K"]; v=ENVIRON["V"]} index($0, k "=")==1 {$0=k "=" v} {print}' "$env_file" > "$tmp"
        cat "$tmp" > "$env_file"
        rm -f "$tmp"
    else
        # A file whose last line has no trailing newline would otherwise
        # get this key glued onto the end of that line.
        if [[ -s "$env_file" && -n "$(tail -c1 "$env_file")" ]]; then
            printf '\n' >> "$env_file"
        fi
        printf '%s=%s\n' "$key" "$val" >> "$env_file"
    fi
}

# Removes KEY from a .env file, in place (same symlink reasoning as
# write_env_var). No-op if the file or key isn't there.
unset_env_var() {
    local env_file="$1" key="$2"
    [[ -f "$env_file" ]] || return 0
    grep -q "^${key}=" "$env_file" 2>/dev/null || return 0
    local tmp; tmp="$(mktemp)"
    K="$key" awk 'BEGIN{k=ENVIRON["K"]} index($0, k "=")!=1 {print}' "$env_file" > "$tmp"
    cat "$tmp" > "$env_file"
    rm -f "$tmp"
}

read_env_var() {
    local env_file="$1" key="$2"
    [[ -f "$env_file" ]] || return 1
    grep "^${key}=" "$env_file" | head -n1 | cut -d= -f2-
}
