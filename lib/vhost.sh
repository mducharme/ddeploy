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
    local name="$1" dir="$2" owner="${3:-www-$name}"
    chown -R "$owner:www-data" "$dir"
    find "$dir" -type d -exec chmod 2750 {} +
    find "$dir" -type f -exec chmod 640 {} +
}

# $3/$4 (optional) pool user/group — default to the site's own
# www-<name>. See apply_permissions for why a preview might override this.
install_fpm_pool() {
    local name="$1" ver="$2" pool_user="${3:-www-$name}" pool_group="${4:-www-$name}"
    local pool_dir="/etc/php/$ver/fpm/pool.d"
    [[ -d "$pool_dir" ]] || die "no such PHP-FPM pool dir: $pool_dir (is php$ver-fpm installed?)"
    render_template "$PROVISIONER_DIR/templates/fpm-pool.conf.tmpl" "$pool_dir/$name.conf" \
        "NAME=$name" "POOL_USER=$pool_user" "POOL_GROUP=$pool_group"
    systemctl reload "php${ver}-fpm" 2>/dev/null || systemctl restart "php${ver}-fpm"
    log_info "installed FPM pool for $name (php$ver, user=$pool_user)"
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
build_auth_block() {
    local name="$1" auth="$2"
    [[ "$auth" == "true" ]] || return 0
    local htpasswd_dir="/etc/nginx/htpasswd"
    mkdir -p "$htpasswd_dir"
    if [[ ! -f "$htpasswd_dir/$name" ]]; then
        log_warn "basic auth enabled for $name but no htpasswd file at $htpasswd_dir/$name — create one with: htpasswd -c $htpasswd_dir/$name <user>"
    fi
    printf '    auth_basic "Restricted";\n    auth_basic_user_file %s/%s;' "$htpasswd_dir" "$name"
}

install_vhost() {
    local name="$1" root="$2" auth="$3"; shift 3
    local server_names; server_names="$(build_server_names "$name" "$@")"
    local auth_block; auth_block="$(build_auth_block "$name" "$auth")"

    render_template "$PROVISIONER_DIR/templates/vhost.conf.tmpl" "/etc/nginx/sites-available/$name.conf" \
        "NAME=$name" "SERVER_NAMES=$server_names" "ROOT=$root" "CERT_NAME=$BASE_DOMAIN" "AUTH_BLOCK=$auth_block"

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
