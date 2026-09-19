#!/usr/bin/env bash
# Per-site Linux user, FPM pool, and nginx vhost — the isolation boundary
# between sites.

ensure_site_user() {
    local name="$1" dir="$2"
    if ! id -u "www-$name" >/dev/null 2>&1; then
        useradd --system --no-create-home --home-dir "$dir" --shell /usr/sbin/nologin "www-$name"
        log_info "created system user www-$name"
    fi
}

# $3 (optional) owning user — defaults to the site's own www-<name>.
# A shared-mode preview passes its parent's user instead, so its pool
# and files are owned by the same user that already owns the parent's
# database credentials and uploads it's linking against.
apply_permissions() {
    local name="$1" dir="$2"
    local owner="${3:-www-$name}"
    chown -R "$owner:www-data" "$dir"
    find "$dir" -type d -exec chmod 2750 {} +
    find "$dir" -type f -exec chmod 640 {} +
}

# $3/$4 (optional) pool user/group — default to the site's own
# www-<name>. See apply_permissions for why a preview might override this.
# $5 (optional) pm.max_children — defaults to the server-wide
# FPM_MAX_CHILDREN (provisioner.conf); callers pass the site's own
# FPM_MAX_CHILDREN_CONFIG override (.ddeploy/config.yaml) when set.
install_fpm_pool() {
    local name="$1" ver="$2"
    local pool_user="${3:-www-$name}" pool_group="${4:-www-$name}"
    local max_children="${5:-$FPM_MAX_CHILDREN}"
    local pool_dir="/etc/php/$ver/fpm/pool.d"
    [[ -d "$pool_dir" ]] || die "no such PHP-FPM pool dir: $pool_dir (is php$ver-fpm installed?)"
    render_template "$PROVISIONER_DIR/templates/fpm-pool.conf.tmpl" "$pool_dir/$name.conf" \
        "NAME=$name" "POOL_USER=$pool_user" "POOL_GROUP=$pool_group" "MAX_CHILDREN=$max_children"
    systemctl reload "php${ver}-fpm" 2>/dev/null || systemctl restart "php${ver}-fpm"
    log_info "installed FPM pool for $name (php$ver, user=$pool_user, pm.max_children=$max_children)"
}

remove_fpm_pool() {
    local name="$1" ver="$2"
    local f="/etc/php/$ver/fpm/pool.d/$name.conf"
    if [[ -f "$f" ]]; then
        rm -f "$f"
        systemctl reload "php${ver}-fpm" 2>/dev/null || true
        log_info "removed FPM pool for $name"
    fi
}

# Builds the space-joined server_name list: <name>.$BASE_DOMAIN plus each
# additional_hostname under the same base domain.
build_server_names() {
    local name="$1"; shift
    local names="$name.$BASE_DOMAIN"
    local h
    for h in "$@"; do
        names="$names $h.$BASE_DOMAIN"
    done
    echo "$names"
}

# Prints the auth_basic block for a site (empty string if auth is off).
# nginx doesn't validate that auth_basic_user_file exists at `nginx -t`
# time — a missing one only fails at request time, as a 500 on every
# request. Since auth defaults on for previews, that would otherwise be
# the out-of-the-box experience for every new one. Uses a per-site
# htpasswd file if one exists at $htpasswd_dir/$name; otherwise falls
# back to the shared default `init` generates (BASIC_AUTH_CREDENTIALS),
# which always exists once init has run — so this only warns (rather
# than silently shipping a broken vhost) in the degenerate case where
# even that's missing.
build_auth_block() {
    local name="$1" auth="$2"
    [[ "$auth" == "true" ]] || return 0
    local htpasswd_dir="/etc/nginx/htpasswd"
    mkdir -p "$htpasswd_dir"
    local htpasswd_file="$htpasswd_dir/$name"
    if [[ ! -f "$htpasswd_file" ]]; then
        if [[ -n "${BASIC_AUTH_CREDENTIALS:-}" && -f "$BASIC_AUTH_CREDENTIALS" ]]; then
            htpasswd_file="$BASIC_AUTH_CREDENTIALS"
            log_info "basic auth for $name: no per-site htpasswd file, using the shared default ($htpasswd_file)"
        else
            log_warn "basic auth enabled for $name but no per-site file at $htpasswd_file and no shared default available — every request will 500 until one exists; create one with: htpasswd -c $htpasswd_file <user>"
        fi
    fi
    printf '    auth_basic "Restricted";\n    auth_basic_user_file %s;' "$htpasswd_file"
}

# $4 (optional) client_max_body_size — defaults to the server-wide
# CLIENT_MAX_BODY_SIZE (provisioner.conf); callers pass the site's own
# CLIENT_MAX_BODY_SIZE_CONFIG override (.ddeploy/config.yaml) when set.
install_vhost() {
    local name="$1" root="$2" auth="$3" max_body_size="${4:-$CLIENT_MAX_BODY_SIZE}"; shift 4
    local server_names; server_names="$(build_server_names "$name" "$@")"
    local auth_block; auth_block="$(build_auth_block "$name" "$auth")"

    render_template "$PROVISIONER_DIR/templates/vhost.conf.tmpl" "/etc/nginx/sites-available/$name.conf" \
        "NAME=$name" "SERVER_NAMES=$server_names" "ROOT=$root" "CERT_NAME=$BASE_DOMAIN" \
        "AUTH_BLOCK=$auth_block" "MAX_BODY_SIZE=$max_body_size"

    ln -sf "/etc/nginx/sites-available/$name.conf" "/etc/nginx/sites-enabled/$name.conf"
    nginx -t
    systemctl reload nginx
    log_info "installed vhost for $name ($server_names)"
}

remove_vhost() {
    local name="$1"
    rm -f "/etc/nginx/sites-enabled/$name.conf" "/etc/nginx/sites-available/$name.conf"
    nginx -t && systemctl reload nginx
    log_info "removed vhost for $name"
}
