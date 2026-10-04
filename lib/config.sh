#!/usr/bin/env bash
# Resolves a site's PHP version, docroot, hostnames and deploy steps from
# .ddev/config.yaml, a previously-written sidecar, or interactive/--flag
# input, normalizing all three into the same globals plus a steps file
# hooks.sh can replay.
#
# Populates on success: PHP_VERSION DOCROOT WEBSERVER_TYPE DB_NAME DB_USER
# DB_ENV_SCHEME ADDITIONAL_HOSTNAMES[] ADDITIONAL_FQDNS[] UPLOAD_DIRS[]
# PERSISTENT_FILES[] AUTH_EXEMPT_PATHS[] BACKUP_EXCLUDE[]
# PHP_INI_OVERRIDES[] BASIC_AUTH_CONFIG CLIENT_MAX_BODY_SIZE_CONFIG
# FPM_MAX_CHILDREN_CONFIG DB_BACKUP_RETENTION_DAYS_CONFIG (the scalar
# _CONFIG ones empty unless overridden — see README ".ddeploy/config.yaml"),
# SECURITY_HEADERS STATIC_CACHE DENY_PHP_IN_UPLOADS DENY_PHP_PATHS[]
# REDIRECTS[] (from<TAB>to<TAB>code), QUEUE_WORKERS[] SCHEDULE[]
# (cron<TAB>cmd — see lib/queue.sh, README "Queue workers & scheduled
# tasks"), DEPLOY_BRANCH (empty unless the
# operator set one — see README "Default branch"),
# NODE_VERSION_SPEC NODE_VERSION_SOURCE (resolved to an installed
# toolchain later, by prepare_site_node — lib/node.sh), BUILD_ENABLED
# BUILD_PATH BUILD_PACKAGE_MANAGER BUILD_INSTALL BUILD_SCRIPT
# BUILD_COMMAND BUILD_ENV[] BUILD_OUTPUTS[] BUILD_KEEP_NODE_MODULES
# (README "Frontend builds"),
# and writes $GENERATED_DIR/<name>.steps (TYPE<TAB>CMD per line, TYPE in
# exec|composer|exec-host|node).
#
# DB_NAME_OVERRIDE DB_USER_OVERRIDE ADDITIONAL_HOSTNAMES_OVERRIDE
# ADDITIONAL_FQDNS_OVERRIDE UPLOAD_DIRS_OVERRIDE DEPLOY_CMDS_OVERRIDE, set
# by the caller before invoking parse_config (cmd_provision.sh's --db/
# --hostnames/--custom-domains/--upload-dirs/--deploy-cmd), win over
# whatever config declared regardless of whether that config already
# existed — consumed and unset here, so they never leak into a later
# parse_config call in the same process.

# Path-safety check for a relative path pulled from a project's own
# config (docroot, an upload_dirs entry). These get used in filesystem
# operations (some of them, like a preview's `rm -rf` when relinking
# uploads, destructive) that assume the value stays inside the site's
# own directory — reject anything that could escape it: an absolute
# path, a '..' segment, or an embedded newline (which could otherwise
# inject extra lines into a rendered template).
validate_relative_path() {
    local val="$1" label="$2"
    [[ -z "$val" ]] && return 0
    [[ "$val" == *$'\n'* ]] && die "$label contains a newline — refusing to use it"
    [[ "$val" == /* ]] && die "$label is an absolute path ('$val') — refusing to use it"
    case "/$val/" in
        */../*) die "$label contains a '..' segment ('$val') — refusing to use it" ;;
    esac
}

# Lexically normalizes $2 (a DOCROOT-relative path — DDEV's own convention
# for upload_dirs, the same one `ddev pull`/`ddev push` use) against $1
# (DOCROOT, itself relative to the site root) into a single site-root-
# relative path. Pure string manipulation, no filesystem access — the
# target directory doesn't necessarily exist yet at provision time. Prints
# the resolved path and returns 0, or returns 1 if it would escape above
# the site's own root entirely (the real security boundary: a path that
# overruns the site root could reach another site's directory — a '..'
# that only climbs back out of the docroot, e.g. a private, non-web-
# exposed uploads dir living next to a "web" docroot, is a normal layout,
# not an escape).
resolve_docroot_relative() {
    local docroot="$1" rel="$2"
    local -a stack=()
    local seg parts
    IFS='/' read -ra parts <<< "${docroot:+$docroot/}$rel"
    for seg in "${parts[@]}"; do
        case "$seg" in
            ''|'.') continue ;;
            '..')
                [[ "${#stack[@]}" -gt 0 ]] || return 1
                unset "stack[$((${#stack[@]}-1))]"
                ;;
            *) stack+=("$seg") ;;
        esac
    done
    local IFS='/'
    echo "${stack[*]}"
}

# Hostname-safety check for additional_hostnames (a single label,
# combined with $BASE_DOMAIN) and additional_fqdns (a complete domain).
# These get embedded into rendered nginx config (server_name) and passed
# as certbot -d arguments — reject anything that isn't a plain hostname,
# so a crafted value can't inject extra nginx directives (YAML allows
# embedded newlines in a string) or be misread as a flag by certbot.
# A git branch name headed for `git fetch origin <val>` / `git checkout
# -B <val>` as its own argv element (never shell-interpolated, so this
# isn't injection defense) — still refused if it could be mistaken for a
# flag by git itself (a leading '-') or isn't a plausible ref name.
validate_branch_name() {
    local val="$1" label="$2"
    [[ -z "$val" ]] && return 0
    [[ "$val" == -* ]] && die "$label ('$val') cannot start with '-' — refusing to use it"
    local re='^[A-Za-z0-9][A-Za-z0-9._/-]*$'
    [[ "$val" =~ $re ]] || die "$label ('$val') is not a plain branch name — refusing to use it"
    case "/$val/" in
        */../*) die "$label ('$val') contains a '..' segment — refusing to use it" ;;
    esac
}

# A preview_branches glob: a branch name, plus * ? [ ] wildcards.
validate_branch_pattern() {
    local val="$1" label="$2"
    [[ "$val" =~ ^[A-Za-z0-9._/*?@+-]+$ ]] \
        || die "$label ('$val') isn't a branch pattern — letters, digits, . _ / - @ + and the wildcards * ?"
}

validate_hostname() {
    local val="$1" label="$2"
    local re='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'
    [[ "$val" =~ $re ]] || die "$label is not a valid hostname ('$val') — refusing to use it"
}

# Absolute URL path embedded into an nginx location/return — same
# charset as auth_exempt_paths. No spaces, quotes, braces, dollars, or
# semicolons: those are how a client-repo value would inject extra
# directives. $1 is the value, $2 a label for the error.
validate_url_path() {
    local val="$1" label="$2"
    local re='^/[A-Za-z0-9/_.~-]*$'
    [[ "$val" =~ $re ]] || die "$label ('$val') is not a plain absolute URL path — refusing to use it"
}

# Redirect target: an internal path (validate_url_path) or an https URL
# whose host/path/query stay inside a charset that cannot break out of
# `return CODE <target>;`. No `$` (nginx variables), no userinfo, no
# protocol-relative `//`, no http:// (force https for off-site).
validate_redirect_target() {
    local val="$1" label="$2"
    if [[ "$val" == /* ]]; then
        validate_url_path "$val" "$label"
        return 0
    fi
    local re='^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{2,5})?(/[A-Za-z0-9/_.~-]*)?(\?[A-Za-z0-9._~=&%-]*)?$'
    [[ "$val" =~ $re ]] || die "$label ('$val') is not a plain URL path or https URL — refusing to use it"
}

# True/false .ddeploy knobs. Empty is false. Anything else is a typo we
# refuse rather than silently treating as on.
validate_bool() {
    local val="$1" label="$2"
    [[ -z "$val" || "$val" == "true" || "$val" == "false" ]] \
        || die "$label ('$val') must be true or false — refusing to use it"
}

# nginx `expires` duration from the client repo. We own the location
# regex; they only pick how long. 1–9999 + s/m/h/d.
validate_static_cache() {
    local val="$1" label="$2"
    [[ -z "$val" ]] && return 0
    local re='^[1-9][0-9]{0,3}[smhd]$'
    [[ "$val" =~ $re ]] || die "$label ('$val') is not an nginx expires duration like 30d / 12h — refusing to use it"
}

# php_version ends up concatenated straight into a filesystem path
# (/etc/php/$ver/fpm/pool.d/<name>.conf, lib/vhost.sh's install_fpm_pool)
# as well as apt package names (php$ver-fpm, lib/php.sh) — an
# unvalidated "8.3/../../etc/cron.d" would let a client repo's own
# php_version: write an arbitrary root-owned file at an attacker-chosen
# path, not just a pool config under pool.d. Plain X.Y, nothing else.
validate_php_version() {
    local val="$1" label="$2"
    local re='^[0-9]+\.[0-9]+$'
    [[ "$val" =~ $re ]] || die "$label ('$val') is not a plain X.Y PHP version — refusing to use it"
}

# client_max_body_size goes straight into `client_max_body_size {{...}};`
# (templates/vhost.conf.tmpl) — nginx's own accepted syntax: an integer
# byte count, optionally suffixed k/K/m/M/g/G. A newline or semicolon
# here would inject extra nginx directives, not just a bad size.
validate_body_size() {
    local val="$1" label="$2"
    [[ -z "$val" ]] && return 0
    local re='^[0-9]+[kKmMgG]?$'
    [[ "$val" =~ $re ]] || die "$label ('$val') is not a plain nginx body size like 64m / 256M / 0 — refusing to use it"
}

# fpm_max_children goes straight into `pm.max_children = {{...}}`
# (templates/fpm-pool.conf.tmpl). Capped at 3 digits (999) — this isn't
# just charset safety, an absurd value (FPM will genuinely try to honor
# it, resources permitting) is a real way for one site's config to
# starve the whole box.
validate_max_children() {
    local val="$1" label="$2"
    [[ -z "$val" ]] && return 0
    local re='^[1-9][0-9]{0,2}$'
    [[ "$val" =~ $re ]] || die "$label ('$val') is not a plain positive integer (max 999) — refusing to use it"
}

# db_backup_retention_days is handed to `rclone delete ... --min-age
# "${days}d"` (lib/db_backup.sh) — a positive integer, capped at 4
# digits (9999 days) so a typo'd value can't be misread as an rclone
# flag or produce a nonsensical --min-age.
validate_retention_days() {
    local val="$1" label="$2"
    [[ -z "$val" ]] && return 0
    local re='^[1-9][0-9]{0,3}$'
    [[ "$val" =~ $re ]] || die "$label ('$val') is not a plain positive integer (max 9999) — refusing to use it"
}

# database.name/database.user (or --db) end up interpolated into
# backtick-quoted identifiers and unquoted `'user'@'host'` clauses in
# lib/db.sh's admin SQL (CREATE/ALTER/GRANT/DROP), and also passed as a
# bare positional argument to `mysql` in load_sql_dump_into_db — a plain
# site name defaults DB_NAME/DB_USER and is already NAME_RE-safe (and
# allows a hyphen, hence this allows one too — just not leading, same
# reason as validate_branch_name's leading-'-' guard: a leading hyphen
# risks being read as a `mysql` CLI flag, not a positional db name), but
# a .ddev database.name/user is client-repo content, not this tool's
# own. Nothing in this charset can close a backtick or a quote.
validate_db_identifier() {
    local val="$1" label="$2"
    [[ "$val" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]] || die "$label ('$val') must be letters, digits, underscore, or (non-leading) hyphen only — refusing to use it"
}

# DB_GRANT_HOST is operator config (provisioner.conf), not client YAML,
# but it is still interpolated into 'user'@'host' clauses. Cap it to a
# hostname / IPv4 / IPv6 / '%' charset so a typo or a compromised conf
# cannot close the quote.
validate_db_grant_host() {
    local val="$1"
    [[ "$val" =~ ^[A-Za-z0-9.:_%-]{1,255}$ ]] || die "DB_GRANT_HOST ('$val') is not a hostname, IP, or '%' — refusing to interpolate it into SQL"
}

# A Node version spec, from nodejs_version / .nvmrc / .node-version —
# handed to nvm as its own argv element (never shell-interpolated), but
# still held to the forms ddeploy documents: a (partial) version number
# or an lts alias (or nvm's `node`, the latest release). "lts" alone is
# normalized to "lts/*" by the caller.
validate_node_version_spec() {
    local val="$1" label="$2"
    local re='^(v?[0-9]+(\.[0-9]+){0,2}|lts/(\*|[a-z]+)|node)$'
    [[ "$val" =~ $re ]] || die "$label ('$val') is not a Node version like 22, 22.11.0, or lts/* — refusing to use it"
}

# A schedule[].cron entry: a plain 5-field cron expression, safe charset
# only — this goes straight into a generated /etc/cron.d file, one entry
# per line, so a newline or an unexpected field count would corrupt that
# file's structure rather than just fail to schedule anything.
validate_cron_expr() {
    local val="$1" label="$2"
    local re='^[0-9*/,-]+[[:space:]]+[0-9*/,-]+[[:space:]]+[0-9*/,-]+[[:space:]]+[0-9*/,-]+[[:space:]]+[0-9*/,-]+$'
    [[ "$val" =~ $re ]] || die "$label ('$val') is not a plain 5-field cron expression — refusing to use it"
}

# DOCROOT-relative URL path for a site-root-relative upload_dirs entry,
# or empty if that dir is not web-accessible (e.g. ../private-uploads).
upload_dir_url_path() {
    local site_rel="$1"
    # Strip a trailing slash: DOCROOT is never rejected for having one
    # (validate_relative_path doesn't check for it), but UPLOAD_DIRS
    # entries are already normalized without one (resolve_docroot_relative),
    # so an un-stripped "$doc/" here would build the case pattern below
    # as "doc//*" (a literal double slash) — never matching a normalized
    # entry, silently treating every upload dir as not web-accessible.
    local doc="${DOCROOT%/}"
    if [[ -z "$doc" ]]; then
        printf '/%s\n' "$site_rel"
        return 0
    fi
    case "$site_rel" in
        "$doc"/*) printf '/%s\n' "${site_rel#"$doc"/}" ;;
        "$doc")   printf '/\n' ;;
        *)        return 1 ;;
    esac
}

# .ddeploy/config.yaml (git-tracked, sibling to .ddev/) is where ddeploy-
# only keys belong — additional_hostnames, additional_fqdns,
# persistent_files, db_env_scheme are not real DDEV fields, and stuffing
# them into a real .ddev/config.yaml risks a future DDEV schema
# validation pass (or `ddev config` regenerating the file) silently
# dropping them. If present, it wins for these keys; if absent, they're
# still read from $cfg (a real .ddev/config.yaml with one of these set by
# hand, or the sidecar, which is ddeploy's own file and never at risk
# from DDEV's tooling) — so nothing already relying on that breaks.
ext_config_path() { echo "$(config_checkout_dir "$1")/.ddeploy/config.yaml"; }

# Operator-side override (`ddeploy override`, see README "Overriding
# a project's config without touching the repo") — same key vocabulary
# as .ddeploy/config.yaml, but lives server-side under $GENERATED_DIR,
# never in the client's checkout. Highest precedence of the three: an
# operator flipping a setting shouldn't need repo write access or wait
# for a deploy to pick it up, and shouldn't have their override silently
# lost the next time someone edits .ddeploy/config.yaml either.
override_config_path() { echo "$GENERATED_DIR/$1.override.yaml"; }

# The composer step ddeploy uses whenever it picks one itself (no
# hooks.post-start declared, a detected CMS, the --deploy-cmd and
# interactive fallbacks): production-style — no dev packages, an
# optimized autoloader. A project that needs its dev packages on the
# server sets composer_dev: true (default_composer_args drops --no-dev).
# Steps a project declares itself in hooks.post-start run as declared.
DEFAULT_COMPOSER_INSTALL="install --no-dev --optimize-autoloader"
default_composer_args() {
    if [[ "${COMPOSER_DEV:-}" == "true" ]]; then
        echo "install --optimize-autoloader"
    else
        echo "$DEFAULT_COMPOSER_INSTALL"
    fi
}

# Reads array expression $4 from $1 (operator override, highest
# precedence), else $2 (extension config), else $3 (the site's primary
# config) — first of the three that exists AND actually declares a
# non-empty value for $4 wins. Any of $1/$2/$3 can be empty/nonexistent;
# skipped, not an error.
read_ext_array() {
    local override="$1" ext="$2" cfg="$3" expr="$4"
    local f vals
    for f in "$override" "$ext" "$cfg"; do
        [[ -n "$f" && -f "$f" ]] || continue
        vals="$(yqc "$expr" "$f" 2>/dev/null | grep -vx 'null' || true)"
        if [[ -n "$vals" ]]; then
            printf '%s\n' "$vals"
            return
        fi
    done
}

# Same precedence as read_ext_array, for a scalar expression.
read_ext_scalar() {
    local override="$1" ext="$2" cfg="$3" expr="$4"
    local f val=""
    for f in "$override" "$ext" "$cfg"; do
        [[ -n "$f" && -f "$f" ]] || continue
        val="$(yqc "$expr" "$f" 2>/dev/null)"
        [[ "$val" == "null" ]] && val=""
        [[ -n "$val" ]] && break
    done
    printf '%s' "$val"
}


# Flattens .hooks.post-start (a list of single-key maps, e.g. "- exec: ...")
# into TYPE<TAB>CMD lines. Same shape is used by the sidecar, so this
# works for both ddev configs and our own generated ones.
extract_hooks() {
    local cfg="$1" out="$2" key="${3:-post-start}" count i type val
    : > "$out"
    [[ -f "$cfg" ]] || return 0
    count="$(yqc ".hooks.\"$key\" | length" "$cfg" 2>/dev/null)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    local ddev_node_re='^ddev[[:space:]]+((npm|npx|pnpm|yarn)([[:space:]].*)?)$'
    for ((i = 0; i < count; i++)); do
        type="$(yqc ".hooks.\"$key\"[$i] | to_entries | .[0].key" "$cfg")"
        val="$(yqc ".hooks.\"$key\"[$i] | to_entries | .[0].value" "$cfg")"
        # `exec-host: ddev npm run build` is how most DDEV projects
        # declare a frontend build. Exactly that shape — `ddev` followed
        # directly by a package manager — becomes a plain exec step (run
        # as the site user, Node on PATH). Anything else still mentioning
        # ddev (`... && ddev exec ...`) keeps hitting the guardrail.
        if [[ ( "$type" == "exec" || "$type" == "exec-host" ) && "$val" =~ $ddev_node_re ]]; then
            type="exec"
            val="${BASH_REMATCH[1]}"
        fi
        printf '%s\t%s\n' "$type" "$val" >> "$out"
    done
}

# Whether any exec/composer step in $1 (a .steps file) already runs a
# Node package manager — the project declared its own build in
# hooks.post-start, so no automatic build step is added on top.
steps_run_node() {
    local steps="$1" type cmd
    local re='(^|[[:space:];&|(])(npm|npx|pnpm|yarn|corepack)([[:space:]]|$)'
    [[ -f "$steps" ]] || return 1
    while IFS=$'\t' read -r type cmd; do
        [[ "$type" == "exec" && "$cmd" =~ $re ]] && return 0
    done < "$steps"
    return 1
}

# First meaningful line of an .nvmrc/.node-version: comments and blank
# lines skipped, whitespace and a CRLF trimmed. Empty if none.
read_version_file() {
    local f="$1" line
    [[ -f "$f" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line//$'\r'/}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] && { printf '%s' "$line"; return 0; }
    done < "$f"
}

# Sets NODE_VERSION_SPEC + NODE_VERSION_SOURCE for $1. Precedence:
# operator override > .ddeploy/config.yaml > .ddev/config.yaml (or
# sidecar) nodejs_version — where DDEV's own "auto" (and an empty value)
# means "use .nvmrc" — then .nvmrc / .node-version (build.path's, then
# the repo root's), then DEFAULT_NODE.
resolve_node_version_spec() {
    local name="$1" override_cfg="$2" ext_cfg="$3" cfg="$4" build_path="$5"
    local checkout; checkout="$(config_checkout_dir "$name")"
    local spec source="" f d
    spec="$(read_ext_scalar "$override_cfg" "$ext_cfg" "$cfg" '.nodejs_version // ""')"
    spec="${spec//\"/}"
    [[ "$spec" == "null" || "$spec" == "auto" ]] && spec=""
    [[ -n "$spec" ]] && source="nodejs_version"
    if [[ -z "$spec" ]]; then
        for d in "${build_path:+$checkout/${build_path%/}}" "$checkout"; do
            [[ -n "$d" ]] || continue
            for f in .nvmrc .node-version; do
                spec="$(read_version_file "$d/$f")"
                if [[ -n "$spec" ]]; then
                    source="${d#"$checkout"}/$f"; source="${source#/}"
                    break 2
                fi
            done
        done
    fi
    if [[ -z "$spec" ]]; then
        spec="${DEFAULT_NODE:-}"
        source="default"
    fi
    [[ "$spec" == "lts" || "$spec" == "lts/" ]] && spec="lts/*"
    NODE_VERSION_SPEC="$spec"
    NODE_VERSION_SOURCE="$source"
    [[ -z "$spec" ]] || validate_node_version_spec "$spec" "node version for '$name' (from $source)"
}

# Resets every BUILD_* global to "no build".
reset_build_config() {
    BUILD_ENABLED=false
    BUILD_PATH=""
    BUILD_PACKAGE_MANAGER="auto"
    BUILD_INSTALL=true
    BUILD_SCRIPT="build"
    BUILD_COMMAND=""
    BUILD_ENV=()
    BUILD_OUTPUTS=()
    BUILD_KEEP_NODE_MODULES=false
}

# Reads the `build:` map from $2 into the BUILD_* globals (label $1).
parse_build_map() {
    local name="$1" src="$2" v
    local label="build for '$name'"
    BUILD_PATH="$(yqc '.build.path // ""' "$src")"
    [[ "$BUILD_PATH" == "null" || "$BUILD_PATH" == "." ]] && BUILD_PATH=""
    validate_relative_path "$BUILD_PATH" "$label: path"
    # Also rendered into an nginx location (build_node_deny_block,
    # lib/vhost.sh) when it sits under the docroot — plain path charset only.
    [[ -z "$BUILD_PATH" || "$BUILD_PATH" =~ ^[A-Za-z0-9._/-]+$ ]] \
        || die "$label: path ('$BUILD_PATH') may only contain letters, digits, '.', '_', '-' and '/'"

    BUILD_PACKAGE_MANAGER="$(yqc '.build.package_manager // "auto"' "$src")"
    case "$BUILD_PACKAGE_MANAGER" in
        auto|npm|pnpm|yarn) ;;
        *) die "$label: package_manager ('$BUILD_PACKAGE_MANAGER') must be auto, npm, pnpm, or yarn" ;;
    esac

    # Not `// true`: yq's alternative operator treats a boolean false as
    # missing too, so `install: false` would read back as true.
    BUILD_INSTALL="$(yqc '.build.install' "$src")"
    [[ "$BUILD_INSTALL" == "null" ]] && BUILD_INSTALL=true
    validate_bool "$BUILD_INSTALL" "$label: install"
    BUILD_KEEP_NODE_MODULES="$(yqc '.build.keep_node_modules' "$src")"
    [[ "$BUILD_KEEP_NODE_MODULES" == "null" ]] && BUILD_KEEP_NODE_MODULES=false
    validate_bool "$BUILD_KEEP_NODE_MODULES" "$label: keep_node_modules"

    local script command
    script="$(yqc '.build.script // ""' "$src")"
    command="$(yqc '.build.command // ""' "$src")"
    [[ "$script" == "null" ]] && script=""
    [[ "$command" == "null" ]] && command=""
    [[ -n "$script" && -n "$command" ]] && die "$label: set script: or command:, not both"
    if [[ -n "$command" ]]; then
        [[ "$command" != *$'\n'* ]] || die "$label: command contains a newline — refusing to use it"
        guardrail_match "$command" && die "$label: command references ddev/a container path — refusing to use it"
        BUILD_COMMAND="$command"
        BUILD_SCRIPT=""
    else
        BUILD_SCRIPT="${script:-build}"
        [[ "$BUILD_SCRIPT" =~ ^[A-Za-z0-9:._-]+$ ]] || die "$label: script ('$BUILD_SCRIPT') must be a plain package.json script name"
    fi

    # Passed to `env` as separate argv elements (never through a shell),
    # but still a closed key charset, and no newline in a value.
    mapfile -t BUILD_ENV < <(yqc '(.build.env // {}) | to_entries | .[] | .key + "=" + (.value | tostring)' "$src" 2>/dev/null)
    (( ${#BUILD_ENV[@]} > 30 )) && die "$label: env has more than 30 entries — refusing to use it"
    for v in "${BUILD_ENV[@]}"; do
        [[ "${v%%=*}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$label: env key '${v%%=*}' is not a plain variable name"
        case "${v%%=*}" in
            PATH|HOME|SSH_AUTH_SOCK|NODE_OPTIONS|LD_PRELOAD|LD_LIBRARY_PATH|BASH_ENV|ENV)
                die "$label: env cannot set ${v%%=*}" ;;
        esac
        [[ "${v#*=}" != *$'\n'* ]] || die "$label: env value for '${v%%=*}' contains a newline"
    done

    mapfile -t BUILD_OUTPUTS < <(yqc '.build.outputs[]' "$src" 2>/dev/null | grep -vx 'null' || true)
    (( ${#BUILD_OUTPUTS[@]} > 30 )) && die "$label: outputs has more than 30 entries — refusing to use it"
    for v in "${BUILD_OUTPUTS[@]}"; do
        [[ -n "$v" ]] || die "$label: empty outputs entry"
        validate_relative_path "${v%/}" "$label: outputs entry"
    done
}

# Resolves BUILD_* for $1 and, when a build is on, inserts a `node` step
# into the .steps file — after the last composer step (a build that
# reads vendor/, e.g. Tailwind content globs or a Laravel Vite plugin,
# needs it installed first), before migrations/cache-clears. Sources:
#   - operator override `build: false` — always off;
#   - `build:` in .ddeploy/config.yaml (or the primary config): a map
#     (explicit settings), `true` (auto settings, required), or `false`;
#   - otherwise automatic, like the composer-install default: a root
#     package.json with a `build` script plus a lockfile, unless
#     hooks.post-start already runs npm/pnpm/yarn itself.
resolve_build_config() {
    local name="$1" override_cfg="$2" ext_cfg="$3" cfg="$4" is_deploy="$5"
    # Mid-parse_config: the steps file being built (see STEPS_OUT there).
    local steps="${STEPS_OUT:-$GENERATED_DIR/$name.steps}"
    local checkout; checkout="$(config_checkout_dir "$name")"
    reset_build_config

    local ov=""
    if [[ -f "$override_cfg" ]]; then
        ov="$(yqc '.build' "$override_cfg" 2>/dev/null)"
        [[ "$ov" == "null" ]] && ov=""
        validate_bool "$ov" "build override for '$name'"
    fi

    local src="" tag="" f
    for f in "$ext_cfg" "$cfg"; do
        [[ -n "$f" && -f "$f" ]] || continue
        tag="$(yqc '.build | tag' "$f" 2>/dev/null || true)"
        [[ -n "$tag" && "$tag" != "!!null" ]] && { src="$f"; break; }
    done

    local mode="auto"
    if [[ "$ov" == "false" ]]; then
        mode="off"
    elif [[ -n "$src" ]]; then
        case "$tag" in
            '!!map') mode="explicit"; parse_build_map "$name" "$src" ;;
            '!!bool')
                if [[ "$(yqc '.build' "$src")" == "true" ]]; then mode="required"; else mode="off"; fi
                ;;
            *) die "build for '$name' must be a map, true, or false — refusing to use it" ;;
        esac
    fi
    [[ "$mode" == "off" ]] && return 0

    local pkg="$checkout"
    [[ -n "$BUILD_PATH" ]] && pkg="$checkout/${BUILD_PATH%/}"
    local has_script=""
    if [[ -f "$pkg/package.json" && -z "$BUILD_COMMAND" ]]; then
        has_script="$(yq -p json eval ".scripts.\"$BUILD_SCRIPT\" // \"\"" "$pkg/package.json" 2>/dev/null || true)"
    fi

    case "$mode" in
        auto)
            [[ -f "$pkg/package.json" && -n "$has_script" ]] || return 0
            if steps_run_node "$steps" || steps_run_node "${POST_DEPLOY_STEPS:-}"; then
                [[ "$is_deploy" == "1" ]] && log_info "'$name': the deploy steps already run a Node package manager — no automatic build step added"
                return 0
            fi
            if ! has_node_lockfile "$pkg"; then
                [[ "$is_deploy" == "1" ]] && log_warn "'$name': package.json has a '$BUILD_SCRIPT' script but no lockfile — NOT building it automatically; commit a lockfile or declare build: in .ddeploy/config.yaml"
                return 0
            fi
            [[ "$is_deploy" == "1" ]] && log_info "'$name': package.json '$BUILD_SCRIPT' script + lockfile found — building the frontend on deploy (build: false in .ddeploy/config.yaml to turn off)"
            ;;
        explicit|required)
            [[ -f "$pkg/package.json" ]] || die "build for '$name': no package.json at '${BUILD_PATH:-.}'"
            [[ -n "$BUILD_COMMAND" || -n "$has_script" ]] || die "build for '$name': package.json has no '$BUILD_SCRIPT' script"
            ;;
    esac

    if [[ "$NODE_ENABLED" != "true" ]]; then
        log_warn "'$name': a frontend build is configured but NODE_ENABLED=false on this server — NOT building it"
        return 0
    fi
    BUILD_ENABLED=true

    # Insert after the last composer line (or first, if none).
    local tmp; tmp="$(mktemp)"
    awk -v label="build ${BUILD_PATH:-.}" '
        { lines[NR] = $0; if ($0 ~ /^composer\t/) last = NR }
        END {
            if (!last) print "node\t" label
            for (i = 1; i <= NR; i++) { print lines[i]; if (i == last) print "node\t" label }
        }' "$steps" > "$tmp" 2>/dev/null || printf 'node\tbuild %s\n' "${BUILD_PATH:-.}" > "$tmp"
    mv "$tmp" "$steps"
}

# $1 name, $2 path to a config.yaml-shaped file, $3 "is_deploy" (1/0) —
# gates informational messages that are only relevant when this call is
# actually part of building/redeploying the site (webserver_type,
# defaulting to composer install), not every read-only caller
# (backup-uploads/backup-database/doctor/list/restore all call this
# per-site too, and would otherwise repeat the same "defaulting to
# composer install" line on every single run for every site with no
# explicit hooks.post-start — confirmed noisy in production). $4
# "skip_name_check" (1/0) — a preview's own .ddev/config.yaml is the
# same file (same declared name:) as its parent's, since nobody edits
# that field per-branch; resolve_preview_config passes 1 here so a
# preview whose branch carries a real ddev config doesn't hard-fail on a
# mismatch that's expected, not a sign of the wrong repo.
parse_config() {
    local name="$1" cfg="$2" is_deploy="${3:-0}" skip_name_check="${4:-0}"
    require_yq
    [[ -f "$cfg" ]] || die "config not found: $cfg"
    # One yq run per file for everything below (see yqc in common.sh).
    yqc_prime "$cfg" "$(ext_config_path "$name")" "$(override_config_path "$name")"

    local cfg_name
    cfg_name="$(yqc '.name' "$cfg")"
    if [[ "$skip_name_check" != "1" ]]; then
        [[ "$cfg_name" == "$name" ]] || die "'name: $cfg_name' in $cfg does not match directory name '$name'"
    fi

    PHP_VERSION="$(yqc '.php_version' "$cfg")"
    [[ "$PHP_VERSION" != "null" && -n "$PHP_VERSION" ]] || PHP_VERSION="$DEFAULT_PHP"
    PHP_VERSION="${PHP_VERSION//\"/}"
    validate_php_version "$PHP_VERSION" "php_version for '$name'"

    DOCROOT="$(yqc '.docroot // ""' "$cfg")"
    [[ "$DOCROOT" == "null" ]] && DOCROOT=""
    validate_relative_path "$DOCROOT" "docroot for '$name'"

    if [[ "$is_deploy" == "1" ]]; then
        # Sites are always served via nginx + PHP-FPM regardless of this
        # value — it's informational only, not a compatibility gate.
        WEBSERVER_TYPE="$(yqc '.webserver_type' "$cfg")"
        [[ "$WEBSERVER_TYPE" == "null" ]] && WEBSERVER_TYPE=""
        if [[ -n "$WEBSERVER_TYPE" && "$WEBSERVER_TYPE" != "nginx-fpm" ]]; then
            log_info "'$name' uses webserver_type: $WEBSERVER_TYPE in DDEV — serving it via nginx-fpm here regardless. If it relies on .htaccess rules beyond the standard front-controller rewrite, those need manual translation into the vhost."
        fi
    fi

    local ext_cfg; ext_cfg="$(ext_config_path "$name")"
    local override_cfg; override_cfg="$(override_config_path "$name")"
    mapfile -t ADDITIONAL_HOSTNAMES < <(read_ext_array "$override_cfg" "$ext_cfg" "$cfg" '.additional_hostnames[]')
    mapfile -t ADDITIONAL_FQDNS    < <(read_ext_array "$override_cfg" "$ext_cfg" "$cfg" '.additional_fqdns[]')

    # Operator-set (README "Default branch"), never read from the repo
    # itself — see lib/releases.sh. Informational at this point: the
    # actual branch switch (if any) already happened before this release
    # was built.
    DEPLOY_BRANCH="$(read_deploy_branch "$name")"

    # ADDITIONAL_HOSTNAMES_OVERRIDE/ADDITIONAL_FQDNS_OVERRIDE (set by
    # cmd_provision.sh's --hostnames/--custom-domains) win over whatever
    # config declared, the same way DB_NAME_OVERRIDE already does below —
    # unlike the old behavior, where these flags only had any effect the
    # very first time a site was provisioned (before a config existed),
    # then silently stopped applying once one did.
    if [[ -n "${ADDITIONAL_HOSTNAMES_OVERRIDE:-}" ]]; then
        read -ra ADDITIONAL_HOSTNAMES <<< "$ADDITIONAL_HOSTNAMES_OVERRIDE"
    fi
    if [[ -n "${ADDITIONAL_FQDNS_OVERRIDE:-}" ]]; then
        read -ra ADDITIONAL_FQDNS <<< "$ADDITIONAL_FQDNS_OVERRIDE"
    fi
    unset ADDITIONAL_HOSTNAMES_OVERRIDE ADDITIONAL_FQDNS_OVERRIDE

    # Per-site overrides of server-wide provisioner.conf defaults — empty
    # here means "use the server default", resolved by the caller
    # (cmd_provision.sh/cmd_preview.sh), not here, since the default
    # itself (BASIC_AUTH_DEFAULT vs. previews' own true-by-default, say)
    # varies by caller.
    BASIC_AUTH_CONFIG="$(read_ext_scalar "$override_cfg" "$ext_cfg" "$cfg" '.basic_auth // ""')"
    [[ "$BASIC_AUTH_CONFIG" == "null" ]] && BASIC_AUTH_CONFIG=""
    # Every caller only ever checks this against the literal string
    # "true" — without this, a typo ("True", "yes", "1") silently reads
    # as "false" and basic auth just never turns on, no error, no sign
    # anything's wrong short of noticing the site isn't actually gated.
    validate_bool "$BASIC_AUTH_CONFIG" "basic_auth for '$name'"
    CLIENT_MAX_BODY_SIZE_CONFIG="$(read_ext_scalar "$override_cfg" "$ext_cfg" "$cfg" '.client_max_body_size // ""')"
    [[ "$CLIENT_MAX_BODY_SIZE_CONFIG" == "null" ]] && CLIENT_MAX_BODY_SIZE_CONFIG=""
    validate_body_size "$CLIENT_MAX_BODY_SIZE_CONFIG" "client_max_body_size for '$name'"
    FPM_MAX_CHILDREN_CONFIG="$(read_ext_scalar "$override_cfg" "$ext_cfg" "$cfg" '.fpm_max_children // ""')"
    [[ "$FPM_MAX_CHILDREN_CONFIG" == "null" ]] && FPM_MAX_CHILDREN_CONFIG=""
    validate_max_children "$FPM_MAX_CHILDREN_CONFIG" "fpm_max_children for '$name'"
    # composer_dev: keep dev packages in ddeploy's own composer step (see
    # default_composer_args).
    COMPOSER_DEV="$(read_ext_scalar "$override_cfg" "$ext_cfg" "$cfg" '.composer_dev // ""')"
    validate_bool "$COMPOSER_DEV" "composer_dev for '$name'"

    local v
    for v in "${ADDITIONAL_HOSTNAMES[@]}"; do validate_hostname "$v" "additional_hostnames entry for '$name'"; done
    for v in "${ADDITIONAL_FQDNS[@]}"; do validate_hostname "$v" "additional_fqdns entry for '$name'"; done

    # upload_dirs entries are DOCROOT-relative (DDEV's own convention) —
    # resolved here into site-root-relative paths so every consumer
    # (backup, restore, preview uploads linking/seeding) can go on treating
    # UPLOAD_DIRS as it always has, unchanged.
    local raw_upload_dirs resolved
    mapfile -t raw_upload_dirs < <(yqc '.upload_dirs[]' "$cfg" 2>/dev/null | grep -vx 'null' || true)
    # UPLOAD_DIRS_OVERRIDE (--upload-dirs): same win-over-config treatment
    # as the hostnames/fqdns overrides above — replaces the raw, still-
    # docroot-relative list before it goes through the same resolution
    # loop below, so an override is subject to the exact same escape
    # check as a config-declared value.
    if [[ -n "${UPLOAD_DIRS_OVERRIDE:-}" ]]; then
        read -ra raw_upload_dirs <<< "$UPLOAD_DIRS_OVERRIDE"
    fi
    unset UPLOAD_DIRS_OVERRIDE
    UPLOAD_DIRS=()
    for v in "${raw_upload_dirs[@]}"; do
        [[ "$v" == *$'\n'* ]] && die "upload_dirs entry for '$name' contains a newline — refusing to use it ('$v')"
        [[ "$v" == /* ]] && die "upload_dirs entry for '$name' is an absolute path ('$v') — refusing to use it"
        resolved="$(resolve_docroot_relative "$DOCROOT" "$v")" \
            || die "upload_dirs entry for '$name' ('$v') resolves outside the project root — refusing to use it"
        UPLOAD_DIRS+=("$resolved")
    done

    # persistent_files: is a ddeploy-only key (not a real DDEV field) —
    # arbitrary extra paths, beyond upload_dirs and the DB credential
    # file, that should survive `remove --purge-files` (see
    # lib/persistent.sh). Repo-root-relative, so the plain (blind '..'
    # ban) validator is right here, unlike upload_dirs' docroot-relative
    # one — no external convention to honor for a key this tool invented.
    # A trailing '/' marks a directory; without one, a file.
    mapfile -t PERSISTENT_FILES < <(read_ext_array "$override_cfg" "$ext_cfg" "$cfg" '.persistent_files[]')
    for v in "${PERSISTENT_FILES[@]}"; do validate_relative_path "${v%/}" "persistent_files entry for '$name'"; done

    # auth_exempt_paths: URL path prefixes (e.g. a webhook endpoint) that
    # bypass basic auth even when it's otherwise on for this site — see
    # build_auth_exempt_block in lib/vhost.sh. Each gets embedded into a
    # rendered nginx location block, so it's constrained to a safe URL-path
    # charset rather than just banning newlines.
    mapfile -t AUTH_EXEMPT_PATHS < <(read_ext_array "$override_cfg" "$ext_cfg" "$cfg" '.auth_exempt_paths[]')
    for v in "${AUTH_EXEMPT_PATHS[@]}"; do
        validate_url_path "$v" "auth_exempt_paths entry for '$name'"
    done

    # backup_exclude: rclone --exclude glob patterns (e.g. "cache/**"),
    # applied to backup-uploads only — restore naturally only ever pulls
    # back what was actually uploaded, so nothing extra is needed there.
    # Passed to rclone as real argv array elements (lib/backup.sh), never
    # shell-interpolated, so only a newline sanity check is needed, not
    # full path validation — these are glob patterns, not paths.
    mapfile -t BACKUP_EXCLUDE < <(read_ext_array "$override_cfg" "$ext_cfg" "$cfg" '.backup_exclude[]')
    for v in "${BACKUP_EXCLUDE[@]}"; do
        [[ "$v" == *$'\n'* ]] && die "backup_exclude entry for '$name' contains a newline — refusing to use it ('$v')"
    done

    # db_backup_retention_days: per-site override of DB_BACKUP_RETENTION_DAYS.
    DB_BACKUP_RETENTION_DAYS_CONFIG="$(read_ext_scalar "$override_cfg" "$ext_cfg" "$cfg" '.db_backup_retention_days // ""')"
    [[ "$DB_BACKUP_RETENTION_DAYS_CONFIG" == "null" ]] && DB_BACKUP_RETENTION_DAYS_CONFIG=""
    validate_retention_days "$DB_BACKUP_RETENTION_DAYS_CONFIG" "db_backup_retention_days for '$name'"

    # php_ini: a map of PHP directive -> value, rendered as php_admin_value
    # lines in the site's own FPM pool (lib/vhost.sh) — never touches the
    # shared php.ini, so one site's override can't affect any other.
    # Flattened to "key=value" strings; both sides validated since they're
    # interpolated into a rendered ini-style config file PHP-FPM parses —
    # an unconstrained key/value could inject an unrelated directive.
    mapfile -t PHP_INI_OVERRIDES < <(
        [[ -f "$ext_cfg" ]] && yqc '(.php_ini // {}) | to_entries | .[] | .key + "=" + (.value | tostring)' "$ext_cfg" 2>/dev/null
    )
    local ini_key_re='^[A-Za-z_][A-Za-z0-9_.]*$'
    for v in "${PHP_INI_OVERRIDES[@]}"; do
        [[ "${v%%=*}" =~ $ini_key_re ]] || die "php_ini key for '$name' ('${v%%=*}') is not a plain directive name — refusing to use it"
        [[ "${v#*=}" == *$'\n'* ]] && die "php_ini value for '$name' (key '${v%%=*}') contains a newline — refusing to use it"
    done

    # Scoped nginx extras — never raw snippets from the client repo.
    # Values are validated to a charset that cannot inject extra nginx
    # directives; the actual location/header/expires syntax is owned by
    # lib/vhost.sh. An ops-owned file at /etc/nginx/ddeploy-extra/<name>.conf
    # is the escape hatch (root-owned, not from git). A leftover
    # .ddeploy/nginx.conf is ignored, not included.
    local nginx_conf_ignored
    nginx_conf_ignored="$(config_checkout_dir "$name")/.ddeploy/nginx.conf"
    if [[ -e "$nginx_conf_ignored" ]]; then
        log_warn "'$name': .ddeploy/nginx.conf is ignored — raw nginx from the client repo is not loaded. Use redirects/security_headers/static_cache/deny_php_in_uploads, or drop a root-owned file at /etc/nginx/ddeploy-extra/$name.conf"
    fi

    SECURITY_HEADERS="$(read_ext_scalar "$override_cfg" "$ext_cfg" "$cfg" '.security_headers // ""')"
    [[ "$SECURITY_HEADERS" == "null" ]] && SECURITY_HEADERS=""
    validate_bool "$SECURITY_HEADERS" "security_headers for '$name'"
    # On by default — these are plain hardening headers (no CSP, no
    # HSTS) with no realistic case for wanting them off; set
    # security_headers: false in .ddeploy/config.yaml to opt out.
    [[ -z "$SECURITY_HEADERS" ]] && SECURITY_HEADERS="true"

    STATIC_CACHE="$(read_ext_scalar "$override_cfg" "$ext_cfg" "$cfg" '.static_cache // ""')"
    [[ "$STATIC_CACHE" == "null" ]] && STATIC_CACHE=""
    STATIC_CACHE="${STATIC_CACHE//\"/}"
    validate_static_cache "$STATIC_CACHE" "static_cache for '$name'"

    DENY_PHP_IN_UPLOADS="$(read_ext_scalar "$override_cfg" "$ext_cfg" "$cfg" '.deny_php_in_uploads // ""')"
    [[ "$DENY_PHP_IN_UPLOADS" == "null" ]] && DENY_PHP_IN_UPLOADS=""
    validate_bool "$DENY_PHP_IN_UPLOADS" "deny_php_in_uploads for '$name'"
    # On by default — an uploaded .php landing in a web-accessible
    # upload_dirs entry and getting executed is a classic webshell path;
    # set deny_php_in_uploads: false to opt out.
    [[ -z "$DENY_PHP_IN_UPLOADS" ]] && DENY_PHP_IN_UPLOADS="true"

    mapfile -t DENY_PHP_PATHS < <(read_ext_array "$override_cfg" "$ext_cfg" "$cfg" '.deny_php_paths[]')
    local deny_url
    for v in "${DENY_PHP_PATHS[@]}"; do
        [[ -z "$v" ]] && continue
        validate_url_path "$v" "deny_php_paths entry for '$name'"
        [[ "$v" == "/" ]] && die "deny_php_paths entry for '$name' cannot be '/' — that would disable PHP for the whole site"
    done
    if [[ "$DENY_PHP_IN_UPLOADS" == "true" ]]; then
        for v in "${UPLOAD_DIRS[@]}"; do
            deny_url="$(upload_dir_url_path "$v")" || continue
            [[ "$deny_url" == "/" ]] && continue
            validate_url_path "$deny_url" "derived deny_php path for upload_dirs '$v'"
            # Compare with trailing slashes stripped, the same
            # normalization build_deny_php_block (lib/vhost.sh) applies
            # when it renders each entry — otherwise an explicit
            # deny_php_paths: ["/uploads/"] and a derived "/uploads"
            # (upload_dir_url_path never adds a trailing slash) look like
            # two different paths here, but render as the identical
            # nginx location, which `nginx -t` rejects as a duplicate.
            local already=0 d
            for d in "${DENY_PHP_PATHS[@]}"; do
                [[ "${d%/}" == "${deny_url%/}" ]] && { already=1; break; }
            done
            [[ "$already" -eq 0 ]] && DENY_PHP_PATHS+=("$deny_url")
        done
    fi
    (( ${#DENY_PHP_PATHS[@]} > 30 )) && die "deny_php_paths for '$name' has more than 30 entries — refusing to use it"

    REDIRECTS=()
    local redirects_src="" redirects_tag redirects_ext_count
    if [[ -f "$ext_cfg" ]]; then
        redirects_tag="$(yqc '.redirects | tag' "$ext_cfg" 2>/dev/null || true)"
        if [[ "$redirects_tag" == "!!seq" ]]; then
            # An explicit empty list in .ddeploy/config.yaml falls back
            # to the primary config, same as every other overridable
            # array key (read_ext_array: ext wins only when it actually
            # resolves to a non-empty value) — declaring the key isn't
            # enough to win on its own, or redirects would be the one
            # field in this tool that behaves differently from the rest.
            redirects_ext_count="$(yqc '.redirects | length' "$ext_cfg" 2>/dev/null || echo 0)"
            [[ "$redirects_ext_count" =~ ^[0-9]+$ ]] || redirects_ext_count=0
            [[ "$redirects_ext_count" -gt 0 ]] && redirects_src="$ext_cfg"
        elif [[ -n "$redirects_tag" && "$redirects_tag" != "!!null" ]]; then
            die "redirects for '$name' must be a list of {from, to, code} maps — refusing to use it"
        fi
    fi
    if [[ -z "$redirects_src" ]]; then
        redirects_tag="$(yqc '.redirects | tag' "$cfg" 2>/dev/null || true)"
        [[ "$redirects_tag" == "!!seq" ]] && redirects_src="$cfg"
        if [[ -z "$redirects_src" && -n "$redirects_tag" && "$redirects_tag" != "!!null" ]]; then
            die "redirects for '$name' must be a list of {from, to, code} maps — refusing to use it"
        fi
    fi
    if [[ -n "$redirects_src" ]]; then
        local rcount ri rfrom rto rcode
        rcount="$(yqc '.redirects | length' "$redirects_src")"
        [[ "$rcount" =~ ^[0-9]+$ ]] || rcount=0
        (( rcount > 30 )) && die "redirects for '$name' has more than 30 entries — refusing to use it"
        for ((ri = 0; ri < rcount; ri++)); do
            rfrom="$(yqc ".redirects[$ri].from // \"\"" "$redirects_src")"
            rto="$(yqc ".redirects[$ri].to // \"\"" "$redirects_src")"
            rcode="$(yqc ".redirects[$ri].code // 301" "$redirects_src")"
            [[ "$rfrom" == "null" ]] && rfrom=""
            [[ "$rto" == "null" ]] && rto=""
            rcode="${rcode//\"/}"
            [[ -n "$rfrom" && -n "$rto" ]] || die "redirects[$ri] for '$name' needs both from: and to:"
            validate_url_path "$rfrom" "redirects[$ri].from for '$name'"
            validate_redirect_target "$rto" "redirects[$ri].to for '$name'"
            [[ "$rcode" == "301" || "$rcode" == "302" ]] \
                || die "redirects[$ri].code for '$name' ('$rcode') must be 301 or 302"
            REDIRECTS+=("$rfrom"$'\t'"$rto"$'\t'"$rcode")
        done
    fi

    # queue_workers: persistent, supervised systemd services (Craft's
    # `queue/listen`, Laravel's `queue:work`) — see lib/queue.sh. Each
    # entry is a full shell command, same guardrail as a hooks.post-start
    # exec step (a ddev/container-path reference can't have been meant
    # for this environment).
    mapfile -t QUEUE_WORKERS < <(read_ext_array "$override_cfg" "$ext_cfg" "$cfg" '.queue_workers[]')
    (( ${#QUEUE_WORKERS[@]} > 20 )) && die "queue_workers for '$name' has more than 20 entries — refusing to use it"
    for v in "${QUEUE_WORKERS[@]}"; do
        [[ "$v" != *$'\n'* ]] || die "queue_workers entry for '$name' contains a newline — refusing to use it"
        guardrail_match "$v" && log_warn "'$name': queue_workers entry references ddev/a container path — will be SKIPPED: $v"
    done

    # schedule: periodic commands (Craft's `queue/run`/`gc`, Laravel's
    # `schedule:run`) — a cron expression + command pair each, same
    # {from,to,code}-style precedence as redirects above (ext_cfg wins
    # only if it actually declares a non-empty list).
    SCHEDULE=()
    local schedule_src="" schedule_tag schedule_ext_count
    if [[ -f "$ext_cfg" ]]; then
        schedule_tag="$(yqc '.schedule | tag' "$ext_cfg" 2>/dev/null || true)"
        if [[ "$schedule_tag" == "!!seq" ]]; then
            schedule_ext_count="$(yqc '.schedule | length' "$ext_cfg" 2>/dev/null || echo 0)"
            [[ "$schedule_ext_count" =~ ^[0-9]+$ ]] || schedule_ext_count=0
            [[ "$schedule_ext_count" -gt 0 ]] && schedule_src="$ext_cfg"
        elif [[ -n "$schedule_tag" && "$schedule_tag" != "!!null" ]]; then
            die "schedule for '$name' must be a list of {cron, cmd} maps — refusing to use it"
        fi
    fi
    if [[ -z "$schedule_src" ]]; then
        schedule_tag="$(yqc '.schedule | tag' "$cfg" 2>/dev/null || true)"
        [[ "$schedule_tag" == "!!seq" ]] && schedule_src="$cfg"
        if [[ -z "$schedule_src" && -n "$schedule_tag" && "$schedule_tag" != "!!null" ]]; then
            die "schedule for '$name' must be a list of {cron, cmd} maps — refusing to use it"
        fi
    fi
    if [[ -n "$schedule_src" ]]; then
        local scount si scron scmd
        scount="$(yqc '.schedule | length' "$schedule_src")"
        [[ "$scount" =~ ^[0-9]+$ ]] || scount=0
        (( scount > 20 )) && die "schedule for '$name' has more than 20 entries — refusing to use it"
        for ((si = 0; si < scount; si++)); do
            scron="$(yqc ".schedule[$si].cron // \"\"" "$schedule_src")"
            scmd="$(yqc ".schedule[$si].cmd // \"\"" "$schedule_src")"
            [[ "$scron" == "null" ]] && scron=""
            [[ "$scmd" == "null" ]] && scmd=""
            [[ -n "$scron" && -n "$scmd" ]] || die "schedule[$si] for '$name' needs both cron: and cmd:"
            validate_cron_expr "$scron" "schedule[$si].cron for '$name'"
            [[ "$scmd" != *$'\n'* ]] || die "schedule[$si].cmd for '$name' contains a newline — refusing to use it"
            guardrail_match "$scmd" && log_warn "'$name': schedule[$si].cmd references ddev/a container path — will be SKIPPED: $scmd"
            SCHEDULE+=("$scron"$'\t'"$scmd")
        done
    fi

    # PARSE_CONFIG_QUIET: read-only callers (doctor) — provisioning
    # advice is noise in a health report.
    if [[ "${#ADDITIONAL_FQDNS[@]}" -gt 0 && "${PARSE_CONFIG_QUIET:-0}" != "1" ]]; then
        log_info "custom domain(s) for '$name': ${ADDITIONAL_FQDNS[*]} — DNS for these must already point at this server; a certificate is requested via HTTP-01 on first provision"
    fi

    # DB_NAME/DB_USER default to the sidecar's own database: block (a
    # real ddev config only has database.type/version, unrelated), then
    # to <name>. DB_NAME_OVERRIDE/DB_USER_OVERRIDE (set by --db) win when
    # present, and are consumed immediately so they can't leak into a
    # later parse_config call in the same process (e.g. `list`'s loop).
    local cfg_db_name cfg_db_user
    cfg_db_name="$(yqc '.database.name // ""' "$cfg" 2>/dev/null)"
    cfg_db_user="$(yqc '.database.user // ""' "$cfg" 2>/dev/null)"
    [[ "$cfg_db_name" == "null" ]] && cfg_db_name=""
    [[ "$cfg_db_user" == "null" ]] && cfg_db_user=""

    DB_NAME="${DB_NAME_OVERRIDE:-${cfg_db_name:-$name}}"
    DB_USER="${DB_USER_OVERRIDE:-${cfg_db_user:-$name}}"
    unset DB_NAME_OVERRIDE DB_USER_OVERRIDE
    validate_db_identifier "$DB_NAME" "database.name for '$name'"
    validate_db_identifier "$DB_USER" "database.user for '$name'"

    # DB_ENV_SCHEME picks which credential format db_ensure writes. A
    # config that recorded one (.ddeploy/config.yaml, or our sidecar)
    # wins; otherwise detect from the checked-out repo, so a real
    # .ddev/config.yaml (which never has this field) still gets it right.
    DB_ENV_SCHEME="$(read_ext_scalar "$override_cfg" "$ext_cfg" "$cfg" '.db_env_scheme // ""')"
    [[ "$DB_ENV_SCHEME" == "null" ]] && DB_ENV_SCHEME=""
    if [[ -z "$DB_ENV_SCHEME" ]]; then
        local detected_cms; detected_cms="$(detect_cms "$(config_checkout_dir "$name")")"
        cms_defaults "$detected_cms"
        DB_ENV_SCHEME="$CMS_DB_ENV_SCHEME"
    fi

    mkdir -p "$GENERATED_DIR"
    # Both steps files are built under a temp name and renamed into place
    # at the end: a deploy runs its hooks from .steps, and a read-only
    # parse (list, doctor, the web UI's api calls) mid-deploy must never
    # hand it a truncated file. Same directory, so the rename is atomic.
    STEPS_OUT="$GENERATED_DIR/.$name.steps.$BASHPID"
    local provision_steps_out="$GENERATED_DIR/.$name.provision-steps.$BASHPID"
    : > "$STEPS_OUT"
    # DEPLOY_CMDS_OVERRIDE (--deploy-cmd): same win-over-config treatment
    # as the overrides above. Unlike those, there's no array to replace —
    # deploy steps live in the .steps file extract_hooks would otherwise
    # write — so this skips extract_hooks entirely and writes the same
    # shape non_interactive_config's fresh-sidecar path already does
    # (composer install, then one exec step per --deploy-cmd value).
    if [[ -n "${DEPLOY_CMDS_OVERRIDE:-}" ]]; then
        {
            printf 'composer\t%s\n' "$(default_composer_args)"
            local cmd
            while IFS= read -r cmd; do
                [[ -n "$cmd" ]] && printf 'exec\t%s\n' "$cmd"
            done <<< "$DEPLOY_CMDS_OVERRIDE"
        } > "$STEPS_OUT"
        log_info "'$name': deploy steps overridden via --deploy-cmd"
        unset DEPLOY_CMDS_OVERRIDE
    elif [[ -f "$ext_cfg" && "$(yqc '.hooks | has("post-start")' "$ext_cfg" 2>/dev/null)" == "true" ]]; then
        # .ddeploy/config.yaml's own hooks.post-start replaces .ddev's on
        # the server — for a project whose DDEV steps are wrong there.
        extract_hooks "$ext_cfg" "$STEPS_OUT" post-start
    else
        extract_hooks "$cfg" "$STEPS_OUT"
        # The sidecar is ddeploy's own file, and its composer step is
        # ddeploy's default (written at provision time): composer_dev
        # applies to it like to the implicit step below. Never to a
        # repo's own .ddev/config.yaml — those steps run as declared.
        if [[ "$COMPOSER_DEV" == "true" && "$cfg" == "$GENERATED_DIR/$name.yaml" ]]; then
            sed -i -E $'/^composer\t/ s/ --no-dev( |$)/\\1/' "$STEPS_OUT"
        fi
    fi

    # A real .ddev/config.yaml frequently declares no hooks.post-start at
    # all — DDEV itself often runs `composer install` implicitly on `ddev
    # start`, which this tool never sees since it doesn't run DDEV. Left
    # alone, a project relying on that implicit behavior silently never
    # gets its dependencies installed (a 500 from a missing
    # vendor/autoload.php, confirmed the hard way). Only kicks in when NO
    # hooks.post-start is declared at all — a config that declares some
    # steps but skips composer is a deliberate choice, not this gap, and
    # is left as-is. Same safe default the no-config-at-all path already
    # applies via CMS detection (config.sh's interactive/non_interactive
    # fallbacks), just extended to also cover "config exists but declares
    # nothing".
    if [[ ! -s "$STEPS_OUT" && -f "$(config_checkout_dir "$name")/composer.json" ]]; then
        printf 'composer\t%s\n' "$(default_composer_args)" > "$STEPS_OUT"
        # The steps file itself is always kept accurate (above), but the
        # explanation is only worth printing when this parse_config call
        # is actually about to act on it (a deploy) — every read-only
        # caller (backup-uploads/backup-database/doctor/list/restore)
        # would otherwise repeat this same line every single run.
        [[ "$is_deploy" == "1" ]] && log_info "'$name': no hooks.post-start declared but composer.json exists — defaulting to 'composer $(default_composer_args)' as the deploy step (composer_dev: true keeps dev packages; hooks.post-start in .ddev/config.yaml or .ddeploy/config.yaml replaces it)"
    fi

    # ddeploy-only steps, from .ddeploy/config.yaml (never .ddev's, which
    # DDEV runs locally too): hooks.post-deploy after everything else,
    # build included, on every deploy; hooks.post-provision once, after a
    # site's or preview's first deploy (its own file, replayed by
    # provision / provision-preview). post-deploy is read before the build
    # is resolved, so a post-deploy step running npm/pnpm/yarn counts as
    # the project building itself (no automatic build on top).
    POST_DEPLOY_STEPS="$(mktemp)"
    extract_hooks "$ext_cfg" "$POST_DEPLOY_STEPS" post-deploy

    # After the steps file is final — the build step is placed relative
    # to its composer steps, and skipped if they already run npm/pnpm/yarn.
    resolve_build_config "$name" "$override_cfg" "$ext_cfg" "$cfg" "$is_deploy"
    resolve_node_version_spec "$name" "$override_cfg" "$ext_cfg" "$cfg" "$BUILD_PATH"

    cat "$POST_DEPLOY_STEPS" >> "$STEPS_OUT"
    rm -f "$POST_DEPLOY_STEPS"
    POST_DEPLOY_STEPS=""
    extract_hooks "$ext_cfg" "$provision_steps_out" post-provision
    mv -f "$STEPS_OUT" "$GENERATED_DIR/$name.steps"
    mv -f "$provision_steps_out" "$GENERATED_DIR/$name.provision-steps"
    STEPS_OUT=""
}

# Writes a sidecar at $GENERATED_DIR/<name>.yaml in the same shape as a
# ddev config.yaml (so parse_config can read either interchangeably).
# $1 name, $2 php_version, $3 docroot, $4 db_name, $5 db_user,
# $6 hostnames (space-separated), $7 db_env_scheme, $8 cms (informational,
# may be empty), $9 custom domains / additional_fqdns (space-separated),
# then remaining args as "TYPE:CMD" steps.
write_sidecar() {
    local name="$1" php="$2" docroot="$3" db_name="$4" db_user="$5" hostnames="$6" db_env_scheme="$7" cms="$8" custom_domains="$9"
    shift 9
    mkdir -p "$GENERATED_DIR"
    local out="$GENERATED_DIR/$name.yaml"
    {
        printf 'name: %s\n' "$name"
        printf 'php_version: "%s"\n' "$php"
        printf 'docroot: %s\n' "${docroot:-\"\"}"
        printf 'webserver_type: nginx-fpm\n'
        printf 'db_env_scheme: %s\n' "${db_env_scheme:-laravel}"
        [[ -n "$cms" ]] && printf 'cms: %s\n' "$cms"
        printf 'database:\n  name: %s\n  user: %s\n' "$db_name" "$db_user"
        if [[ -n "$hostnames" ]]; then
            printf 'additional_hostnames:\n'
            local h; for h in $hostnames; do printf '  - %s\n' "$h"; done
        else
            printf 'additional_hostnames: []\n'
        fi
        if [[ -n "$custom_domains" ]]; then
            printf 'additional_fqdns:\n'
            local d; for d in $custom_domains; do printf '  - %s\n' "$d"; done
        else
            printf 'additional_fqdns: []\n'
        fi
        printf 'hooks:\n  post-start:\n'
        if [[ "$#" -eq 0 ]]; then
            printf '    - composer: "install"\n'
        else
            local step type cmd
            for step in "$@"; do
                type="${step%%:*}"
                cmd="${step#*:}"
                printf '    - %s: "%s"\n' "$type" "$cmd"
            done
        fi
    } > "$out"
    log_info "wrote sidecar config: $out"
}

# Sets upload_dirs: on an already-written sidecar. Separate from
# write_sidecar's positional args since it's an optional, occasional
# addition — a real .ddev/config.yaml already has this key natively and
# never goes through this path.
set_sidecar_upload_dirs() {
    local name="$1" dirs="$2"
    [[ -n "$dirs" ]] || return 0
    require_yq
    local out="$GENERATED_DIR/$name.yaml"
    local expr="[" d first=1
    for d in $dirs; do
        [[ "$first" -eq 1 ]] || expr+=", "
        expr+="\"$d\""
        first=0
    done
    expr+="]"
    yq eval -i ".upload_dirs = $expr" "$out"
}

# Interactive prompts when no .ddev/config.yaml exists. Writes a sidecar
# so subsequent provision/deploy runs are non-interactive.
#
# If a CMS is detected, shows the defaults it would use for docroot and
# deploy steps and offers to skip those specific prompts. A "no" (or no
# detection at all) falls through to asking everything by hand.
interactive_fallback() {
    local name="$1"
    local dir; dir="$(site_dir "$name")"
    log_warn "no .ddev/config.yaml found for '$name' — falling back to interactive setup"

    local cms="" use_detected=0
    cms="$(detect_cms "$dir")"
    if [[ -n "$cms" ]]; then
        cms_defaults "$cms"
        log_info "detected CMS: $cms"
        log_info "  docroot='${CMS_DOCROOT:-.}' composer='$CMS_COMPOSER_ARGS' migrate='${CMS_MIGRATE_CMD:-none}' cache='${CMS_CACHE_CMD:-none}' db_env=$CMS_DB_ENV_SCHEME"
        local confirm
        read -rp "Use these detected defaults for docroot + deploy steps? [Y/n]: " confirm
        [[ "$confirm" =~ ^[Nn] ]] || use_detected=1
    fi

    local php docroot db_name db_user hostnames custom_domains upload_dirs deploy_steps=()
    read -rp "PHP version [$DEFAULT_PHP]: " php; php="${php:-$DEFAULT_PHP}"

    if [[ "$use_detected" -eq 1 ]]; then
        docroot="$CMS_DOCROOT"
    else
        read -rp "docroot (relative to repo root) [none]: " docroot
    fi

    read -rp "DB name [$name]: " db_name; db_name="${db_name:-$name}"
    read -rp "DB user [$db_name]: " db_user; db_user="${db_user:-$db_name}"
    read -rp "additional hostnames (space-separated, under $BASE_DOMAIN) [none]: " hostnames
    read -rp "custom domain(s) (space-separated, e.g. www.client.com — DNS must already point here) [none]: " custom_domains
    read -rp "upload/media directories to back up (space-separated, relative to docroot) [none]: " upload_dirs

    if [[ "$use_detected" -eq 1 ]]; then
        [[ -n "$CMS_COMPOSER_ARGS" ]] && deploy_steps+=("composer:$CMS_COMPOSER_ARGS")
        [[ -n "$CMS_MIGRATE_CMD" ]] && deploy_steps+=("exec:$CMS_MIGRATE_CMD")
        [[ -n "$CMS_CACHE_CMD" ]] && deploy_steps+=("exec:$CMS_CACHE_CMD")
    else
        local composer_args migrate_cmd cache_cmd
        read -rp "composer install args [$DEFAULT_COMPOSER_INSTALL]: " composer_args; composer_args="${composer_args:-$DEFAULT_COMPOSER_INSTALL}"
        deploy_steps+=("composer:$composer_args")
        read -rp "migrate command (blank to skip): " migrate_cmd
        [[ -n "$migrate_cmd" ]] && deploy_steps+=("exec:$migrate_cmd")
        read -rp "cache-clear command (blank to skip): " cache_cmd
        [[ -n "$cache_cmd" ]] && deploy_steps+=("exec:$cache_cmd")
    fi

    local db_env_scheme="laravel"
    [[ "$use_detected" -eq 1 ]] && db_env_scheme="$CMS_DB_ENV_SCHEME"

    # Frontend: only asked when there's a package.json. Accepting the
    # default writes nothing, so a later .nvmrc change is still followed.
    local node_spec="" build_answer=""
    if [[ -f "$dir/package.json" && "$NODE_ENABLED" == "true" ]]; then
        local node_default
        node_default="$(read_version_file "$dir/.nvmrc")"
        [[ -n "$node_default" ]] || node_default="$(read_version_file "$dir/.node-version")"
        node_default="${node_default:-$DEFAULT_NODE}"
        read -rp "Node version for the frontend build [$node_default]: " node_spec
        [[ "$node_spec" == "$node_default" ]] && node_spec=""
        [[ "$node_spec" == "lts" ]] && node_spec="lts/*"
        [[ -z "$node_spec" ]] || validate_node_version_spec "$node_spec" "node version"
        if [[ -n "$(yq -p json eval '.scripts.build // ""' "$dir/package.json" 2>/dev/null || true)" ]]; then
            read -rp "Build the frontend (package.json 'build' script) on every deploy? [Y/n]: " build_answer
        fi
    fi

    write_sidecar "$name" "$php" "$docroot" "$db_name" "$db_user" "$hostnames" "$db_env_scheme" "$cms" "$custom_domains" "${deploy_steps[@]}"
    if [[ -n "$node_spec" ]]; then
        yq eval -i ".nodejs_version = \"$node_spec\"" "$GENERATED_DIR/$name.yaml"
    fi
    if [[ "$build_answer" =~ ^[Nn] ]]; then
        yq eval -i '.build = false' "$GENERATED_DIR/$name.yaml"
    fi
    set_sidecar_upload_dirs "$name" "$upload_dirs"
}

# Non-interactive equivalent of interactive_fallback, driven by CLI flags.
# $2..$6 as write_sidecar; $7 is a newline-separated list of --deploy-cmd
# values (each becomes an "exec" step; composer install is always first);
# $8 is custom domains (space-separated), $9 is upload dirs to back up
# (space-separated). CMS detection only fills gaps: an explicit
# --docroot/--deploy-cmd always wins over a detected default.
non_interactive_config() {
    local name="$1" php="$2" docroot="$3" db_name="$4" db_user="$5" hostnames="$6" deploy_cmds="$7" custom_domains="$8" upload_dirs="$9"
    local dir; dir="$(site_dir "$name")"

    local cms="" db_env_scheme="laravel"
    if [[ -z "$docroot" || -z "$deploy_cmds" ]]; then
        cms="$(detect_cms "$dir")"
        if [[ -n "$cms" ]]; then
            cms_defaults "$cms"
            [[ -z "$docroot" ]] && docroot="$CMS_DOCROOT"
            db_env_scheme="$CMS_DB_ENV_SCHEME"
            log_info "detected CMS: $cms (filling docroot/deploy-steps/db-env-scheme gaps not set by flags)"
        fi
    fi

    local deploy_steps=()
    if [[ -n "$deploy_cmds" ]]; then
        deploy_steps=("composer:$DEFAULT_COMPOSER_INSTALL")
        local cmd
        while IFS= read -r cmd; do
            [[ -n "$cmd" ]] && deploy_steps+=("exec:$cmd")
        done <<< "$deploy_cmds"
    elif [[ -n "$cms" ]]; then
        [[ -n "$CMS_COMPOSER_ARGS" ]] && deploy_steps+=("composer:$CMS_COMPOSER_ARGS")
        [[ -n "$CMS_MIGRATE_CMD" ]] && deploy_steps+=("exec:$CMS_MIGRATE_CMD")
        [[ -n "$CMS_CACHE_CMD" ]] && deploy_steps+=("exec:$CMS_CACHE_CMD")
    else
        deploy_steps=("composer:$DEFAULT_COMPOSER_INSTALL")
    fi

    write_sidecar "$name" "$php" "$docroot" "$db_name" "$db_user" "$hostnames" "$db_env_scheme" "$cms" "$custom_domains" "${deploy_steps[@]}"
    set_sidecar_upload_dirs "$name" "$upload_dirs"
}

# Resolves which config source to use for $name: real ddev config takes
# precedence, then a previously-written sidecar. Returns the path, or
# empty if neither exists.
resolve_config_path() {
    local name="$1"
    local ddev="$(config_checkout_dir "$name")/.ddev/config.yaml"
    local sidecar="$GENERATED_DIR/$name.yaml"
    if [[ -f "$ddev" ]]; then
        echo "$ddev"
    elif [[ -f "$sidecar" ]]; then
        echo "$sidecar"
    fi
}
