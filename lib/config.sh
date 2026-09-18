#!/usr/bin/env bash
# Resolves a site's PHP version, docroot, hostnames and deploy steps from
# .ddev/config.yaml, a previously-written sidecar, or interactive/--flag
# input, normalizing all three into the same globals plus a steps file
# hooks.sh can replay.
#
# Populates on success: PHP_VERSION DOCROOT WEBSERVER_TYPE DB_NAME DB_USER
# DB_ENV_SCHEME ADDITIONAL_HOSTNAMES[] ADDITIONAL_FQDNS[] UPLOAD_DIRS[],
# and writes $GENERATED_DIR/<name>.steps (TYPE<TAB>CMD per line, TYPE in
# exec|composer|exec-host).

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

    if [[ "$check_webserver" == "1" ]]; then
        # Sites are always served via nginx + PHP-FPM regardless of this
        # value — it's informational only, not a compatibility gate.
        WEBSERVER_TYPE="$(yq eval '.webserver_type' "$cfg")"
        [[ "$WEBSERVER_TYPE" == "null" ]] && WEBSERVER_TYPE=""
        if [[ -n "$WEBSERVER_TYPE" && "$WEBSERVER_TYPE" != "nginx-fpm" ]]; then
            log_info "'$name' uses webserver_type: $WEBSERVER_TYPE in DDEV — serving it via nginx-fpm here regardless. If it relies on .htaccess rules beyond the standard front-controller rewrite, those need manual translation into the vhost."
        fi
    fi

    mapfile -t ADDITIONAL_HOSTNAMES < <(yq eval '.additional_hostnames[]' "$cfg" 2>/dev/null | grep -vx 'null' || true)
    mapfile -t ADDITIONAL_FQDNS    < <(yq eval '.additional_fqdns[]' "$cfg" 2>/dev/null | grep -vx 'null' || true)
    mapfile -t UPLOAD_DIRS         < <(yq eval '.upload_dirs[]' "$cfg" 2>/dev/null | grep -vx 'null' || true)

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
    # config that recorded one (our sidecar) wins; otherwise detect from
    # the checked-out repo, so a real .ddev/config.yaml (which never has
    # this field) still gets it right.
    DB_ENV_SCHEME="$(yq eval '.db_env_scheme // ""' "$cfg" 2>/dev/null)"
    [[ "$DB_ENV_SCHEME" == "null" ]] && DB_ENV_SCHEME=""
    if [[ -z "$DB_ENV_SCHEME" ]]; then
        local detected_cms; detected_cms="$(detect_cms "$SITES_ROOT/$name")"
        cms_defaults "$detected_cms"
        DB_ENV_SCHEME="$CMS_DB_ENV_SCHEME"
    fi

    mkdir -p "$GENERATED_DIR"
    extract_hooks "$cfg" "$GENERATED_DIR/$name.steps"
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
    read -rp "upload/media directories to back up (space-separated, relative to repo root) [none]: " upload_dirs

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
