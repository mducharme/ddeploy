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
# and writes $GENERATED_DIR/<name>.steps (TYPE<TAB>CMD per line, TYPE in
# exec|composer|exec-host).
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
validate_hostname() {
    local val="$1" label="$2"
    local re='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'
    [[ "$val" =~ $re ]] || die "$label is not a valid hostname ('$val') — refusing to use it"
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
ext_config_path() { echo "$SITES_ROOT/$1/.ddeploy/config.yaml"; }

# Reads array expression $3 from $1 (extension config, may not exist) if
# it declares the key, else from $2 (the site's primary config).
read_ext_array() {
    local ext="$1" cfg="$2" expr="$3"
    if [[ -f "$ext" ]]; then
        local vals; vals="$(yq eval "$expr" "$ext" 2>/dev/null | grep -vx 'null' || true)"
        if [[ -n "$vals" ]]; then
            printf '%s\n' "$vals"
            return
        fi
    fi
    yq eval "$expr" "$cfg" 2>/dev/null | grep -vx 'null' || true
}

# Same precedence as read_ext_array, for a scalar expression.
read_ext_scalar() {
    local ext="$1" cfg="$2" expr="$3"
    local val=""
    if [[ -f "$ext" ]]; then
        val="$(yq eval "$expr" "$ext" 2>/dev/null)"
        [[ "$val" == "null" ]] && val=""
    fi
    if [[ -z "$val" ]]; then
        val="$(yq eval "$expr" "$cfg" 2>/dev/null)"
        [[ "$val" == "null" ]] && val=""
    fi
    printf '%s' "$val"
}

# Flattens .hooks.post-start (a list of single-key maps, e.g. "- exec: ...")
# into TYPE<TAB>CMD lines. Same shape is used by the sidecar, so this
# works for both ddev configs and our own generated ones.
extract_hooks() {
    local cfg="$1" out="$2" count i type val
    : > "$out"
    count="$(yq eval '.hooks.post-start | length' "$cfg" 2>/dev/null)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    for ((i = 0; i < count; i++)); do
        type="$(yq eval ".hooks.post-start[$i] | to_entries | .[0].key" "$cfg")"
        val="$(yq eval ".hooks.post-start[$i] | to_entries | .[0].value" "$cfg")"
        printf '%s\t%s\n' "$type" "$val" >> "$out"
    done
}

# $1 name, $2 path to a config.yaml-shaped file, $3 "check_webserver" (1/0),
# $4 "skip_name_check" (1/0) — a preview's own .ddev/config.yaml is the
# same file (same declared name:) as its parent's, since nobody edits
# that field per-branch; resolve_preview_config passes 1 here so a
# preview whose branch carries a real ddev config doesn't hard-fail on a
# mismatch that's expected, not a sign of the wrong repo.
parse_config() {
    local name="$1" cfg="$2" check_webserver="${3:-0}" skip_name_check="${4:-0}"
    require_yq
    [[ -f "$cfg" ]] || die "config not found: $cfg"

    local cfg_name
    cfg_name="$(yq eval '.name' "$cfg")"
    if [[ "$skip_name_check" != "1" ]]; then
        [[ "$cfg_name" == "$name" ]] || die "'name: $cfg_name' in $cfg does not match directory name '$name'"
    fi

    PHP_VERSION="$(yq eval '.php_version' "$cfg")"
    [[ "$PHP_VERSION" != "null" && -n "$PHP_VERSION" ]] || PHP_VERSION="$DEFAULT_PHP"
    PHP_VERSION="${PHP_VERSION//\"/}"

    DOCROOT="$(yq eval '.docroot // ""' "$cfg")"
    [[ "$DOCROOT" == "null" ]] && DOCROOT=""
    validate_relative_path "$DOCROOT" "docroot for '$name'"

    if [[ "$check_webserver" == "1" ]]; then
        # Sites are always served via nginx + PHP-FPM regardless of this
        # value — it's informational only, not a compatibility gate.
        WEBSERVER_TYPE="$(yq eval '.webserver_type' "$cfg")"
        [[ "$WEBSERVER_TYPE" == "null" ]] && WEBSERVER_TYPE=""
        if [[ -n "$WEBSERVER_TYPE" && "$WEBSERVER_TYPE" != "nginx-fpm" ]]; then
            log_info "'$name' uses webserver_type: $WEBSERVER_TYPE in DDEV — serving it via nginx-fpm here regardless. If it relies on .htaccess rules beyond the standard front-controller rewrite, those need manual translation into the vhost."
        fi
    fi

    local ext_cfg; ext_cfg="$(ext_config_path "$name")"
    mapfile -t ADDITIONAL_HOSTNAMES < <(read_ext_array "$ext_cfg" "$cfg" '.additional_hostnames[]')
    mapfile -t ADDITIONAL_FQDNS    < <(read_ext_array "$ext_cfg" "$cfg" '.additional_fqdns[]')

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
    BASIC_AUTH_CONFIG="$(read_ext_scalar "$ext_cfg" "$cfg" '.basic_auth // ""')"
    [[ "$BASIC_AUTH_CONFIG" == "null" ]] && BASIC_AUTH_CONFIG=""
    CLIENT_MAX_BODY_SIZE_CONFIG="$(read_ext_scalar "$ext_cfg" "$cfg" '.client_max_body_size // ""')"
    [[ "$CLIENT_MAX_BODY_SIZE_CONFIG" == "null" ]] && CLIENT_MAX_BODY_SIZE_CONFIG=""
    FPM_MAX_CHILDREN_CONFIG="$(read_ext_scalar "$ext_cfg" "$cfg" '.fpm_max_children // ""')"
    [[ "$FPM_MAX_CHILDREN_CONFIG" == "null" ]] && FPM_MAX_CHILDREN_CONFIG=""

    local v
    for v in "${ADDITIONAL_HOSTNAMES[@]}"; do validate_hostname "$v" "additional_hostnames entry for '$name'"; done
    for v in "${ADDITIONAL_FQDNS[@]}"; do validate_hostname "$v" "additional_fqdns entry for '$name'"; done

    # upload_dirs entries are DOCROOT-relative (DDEV's own convention) —
    # resolved here into site-root-relative paths so every consumer
    # (backup, restore, preview uploads linking/seeding) can go on treating
    # UPLOAD_DIRS as it always has, unchanged.
    local raw_upload_dirs resolved
    mapfile -t raw_upload_dirs < <(yq eval '.upload_dirs[]' "$cfg" 2>/dev/null | grep -vx 'null' || true)
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
    mapfile -t PERSISTENT_FILES < <(read_ext_array "$ext_cfg" "$cfg" '.persistent_files[]')
    for v in "${PERSISTENT_FILES[@]}"; do validate_relative_path "${v%/}" "persistent_files entry for '$name'"; done

    # auth_exempt_paths: URL path prefixes (e.g. a webhook endpoint) that
    # bypass basic auth even when it's otherwise on for this site — see
    # build_auth_exempt_block in lib/vhost.sh. Each gets embedded into a
    # rendered nginx location block, so it's constrained to a safe URL-path
    # charset rather than just banning newlines.
    mapfile -t AUTH_EXEMPT_PATHS < <(read_ext_array "$ext_cfg" "$cfg" '.auth_exempt_paths[]')
    local path_re='^/[A-Za-z0-9/_.~-]*$'
    for v in "${AUTH_EXEMPT_PATHS[@]}"; do
        [[ "$v" =~ $path_re ]] || die "auth_exempt_paths entry for '$name' ('$v') is not a plain absolute URL path — refusing to use it"
    done

    # backup_exclude: rclone --exclude glob patterns (e.g. "cache/**"),
    # applied to backup-uploads only — restore naturally only ever pulls
    # back what was actually uploaded, so nothing extra is needed there.
    # Passed to rclone as real argv array elements (lib/backup.sh), never
    # shell-interpolated, so only a newline sanity check is needed, not
    # full path validation — these are glob patterns, not paths.
    mapfile -t BACKUP_EXCLUDE < <(read_ext_array "$ext_cfg" "$cfg" '.backup_exclude[]')
    for v in "${BACKUP_EXCLUDE[@]}"; do
        [[ "$v" == *$'\n'* ]] && die "backup_exclude entry for '$name' contains a newline — refusing to use it ('$v')"
    done

    # db_backup_retention_days: per-site override of DB_BACKUP_RETENTION_DAYS.
    DB_BACKUP_RETENTION_DAYS_CONFIG="$(read_ext_scalar "$ext_cfg" "$cfg" '.db_backup_retention_days // ""')"
    [[ "$DB_BACKUP_RETENTION_DAYS_CONFIG" == "null" ]] && DB_BACKUP_RETENTION_DAYS_CONFIG=""

    # php_ini: a map of PHP directive -> value, rendered as php_admin_value
    # lines in the site's own FPM pool (lib/vhost.sh) — never touches the
    # shared php.ini, so one site's override can't affect any other.
    # Flattened to "key=value" strings; both sides validated since they're
    # interpolated into a rendered ini-style config file PHP-FPM parses —
    # an unconstrained key/value could inject an unrelated directive.
    mapfile -t PHP_INI_OVERRIDES < <(
        [[ -f "$ext_cfg" ]] && yq eval '(.php_ini // {}) | to_entries | .[] | .key + "=" + (.value | tostring)' "$ext_cfg" 2>/dev/null
    )
    local ini_key_re='^[A-Za-z_][A-Za-z0-9_.]*$'
    for v in "${PHP_INI_OVERRIDES[@]}"; do
        [[ "${v%%=*}" =~ $ini_key_re ]] || die "php_ini key for '$name' ('${v%%=*}') is not a plain directive name — refusing to use it"
        [[ "${v#*=}" == *$'\n'* ]] && die "php_ini value for '$name' (key '${v%%=*}') contains a newline — refusing to use it"
    done

    if [[ "${#ADDITIONAL_FQDNS[@]}" -gt 0 ]]; then
        log_info "custom domain(s) for '$name': ${ADDITIONAL_FQDNS[*]} — DNS for these must already point at this server; a certificate is requested via HTTP-01 on first provision"
    fi

    # DB_NAME/DB_USER default to the sidecar's own database: block (a
    # real ddev config only has database.type/version, unrelated), then
    # to <name>. DB_NAME_OVERRIDE/DB_USER_OVERRIDE (set by --db) win when
    # present, and are consumed immediately so they can't leak into a
    # later parse_config call in the same process (e.g. `list`'s loop).
    local cfg_db_name cfg_db_user
    cfg_db_name="$(yq eval '.database.name // ""' "$cfg" 2>/dev/null)"
    cfg_db_user="$(yq eval '.database.user // ""' "$cfg" 2>/dev/null)"
    [[ "$cfg_db_name" == "null" ]] && cfg_db_name=""
    [[ "$cfg_db_user" == "null" ]] && cfg_db_user=""

    DB_NAME="${DB_NAME_OVERRIDE:-${cfg_db_name:-$name}}"
    DB_USER="${DB_USER_OVERRIDE:-${cfg_db_user:-$name}}"
    unset DB_NAME_OVERRIDE DB_USER_OVERRIDE

    # DB_ENV_SCHEME picks which credential format db_ensure writes. A
    # config that recorded one (.ddeploy/config.yaml, or our sidecar)
    # wins; otherwise detect from the checked-out repo, so a real
    # .ddev/config.yaml (which never has this field) still gets it right.
    DB_ENV_SCHEME="$(read_ext_scalar "$ext_cfg" "$cfg" '.db_env_scheme // ""')"
    [[ "$DB_ENV_SCHEME" == "null" ]] && DB_ENV_SCHEME=""
    if [[ -z "$DB_ENV_SCHEME" ]]; then
        local detected_cms; detected_cms="$(detect_cms "$SITES_ROOT/$name")"
        cms_defaults "$detected_cms"
        DB_ENV_SCHEME="$CMS_DB_ENV_SCHEME"
    fi

    mkdir -p "$GENERATED_DIR"
    # DEPLOY_CMDS_OVERRIDE (--deploy-cmd): same win-over-config treatment
    # as the overrides above. Unlike those, there's no array to replace —
    # deploy steps live in the .steps file extract_hooks would otherwise
    # write — so this skips extract_hooks entirely and writes the same
    # shape non_interactive_config's fresh-sidecar path already does
    # (composer install, then one exec step per --deploy-cmd value).
    if [[ -n "${DEPLOY_CMDS_OVERRIDE:-}" ]]; then
        {
            printf 'composer\tinstall\n'
            local cmd
            while IFS= read -r cmd; do
                [[ -n "$cmd" ]] && printf 'exec\t%s\n' "$cmd"
            done <<< "$DEPLOY_CMDS_OVERRIDE"
        } > "$GENERATED_DIR/$name.steps"
        log_info "'$name': deploy steps overridden via --deploy-cmd"
        unset DEPLOY_CMDS_OVERRIDE
    else
        extract_hooks "$cfg" "$GENERATED_DIR/$name.steps"
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
    if [[ ! -s "$GENERATED_DIR/$name.steps" && -f "$SITES_ROOT/$name/composer.json" ]]; then
        printf 'composer\tinstall\n' > "$GENERATED_DIR/$name.steps"
        log_info "'$name': no hooks.post-start declared but composer.json exists — defaulting to 'composer install' as the deploy step (add hooks.post-start to .ddev/config.yaml to override)"
    fi
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
        read -rp "composer install args [install]: " composer_args; composer_args="${composer_args:-install}"
        deploy_steps+=("composer:$composer_args")
        read -rp "migrate command (blank to skip): " migrate_cmd
        [[ -n "$migrate_cmd" ]] && deploy_steps+=("exec:$migrate_cmd")
        read -rp "cache-clear command (blank to skip): " cache_cmd
        [[ -n "$cache_cmd" ]] && deploy_steps+=("exec:$cache_cmd")
    fi

    local db_env_scheme="laravel"
    [[ "$use_detected" -eq 1 ]] && db_env_scheme="$CMS_DB_ENV_SCHEME"

    write_sidecar "$name" "$php" "$docroot" "$db_name" "$db_user" "$hostnames" "$db_env_scheme" "$cms" "$custom_domains" "${deploy_steps[@]}"
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
        deploy_steps=("composer:install")
        local cmd
        while IFS= read -r cmd; do
            [[ -n "$cmd" ]] && deploy_steps+=("exec:$cmd")
        done <<< "$deploy_cmds"
    elif [[ -n "$cms" ]]; then
        [[ -n "$CMS_COMPOSER_ARGS" ]] && deploy_steps+=("composer:$CMS_COMPOSER_ARGS")
        [[ -n "$CMS_MIGRATE_CMD" ]] && deploy_steps+=("exec:$CMS_MIGRATE_CMD")
        [[ -n "$CMS_CACHE_CMD" ]] && deploy_steps+=("exec:$CMS_CACHE_CMD")
    else
        deploy_steps=("composer:install")
    fi

    write_sidecar "$name" "$php" "$docroot" "$db_name" "$db_user" "$hostnames" "$db_env_scheme" "$cms" "$custom_domains" "${deploy_steps[@]}"
    set_sidecar_upload_dirs "$name" "$upload_dirs"
}

# Resolves which config source to use for $name: real ddev config takes
# precedence, then a previously-written sidecar. Returns the path, or
# empty if neither exists.
resolve_config_path() {
    local name="$1"
    local ddev="$SITES_ROOT/$name/.ddev/config.yaml"
    local sidecar="$GENERATED_DIR/$name.yaml"
    if [[ -f "$ddev" ]]; then
        echo "$ddev"
    elif [[ -f "$sidecar" ]]; then
        echo "$sidecar"
    fi
}
