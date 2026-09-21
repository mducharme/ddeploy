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

# Builds php_admin_value[] lines from PHP_INI_OVERRIDES[] (set by
# parse_config from .ddeploy/config.yaml's php_ini: map, "key=value"
# strings) — per-site PHP ini overrides scoped to just this FPM pool,
# never touching the shared php.ini other sites also use.
# php_admin_value (not php_value) so the app itself can't override these
# back at runtime via ini_set — the operator's ceiling actually holds.
build_php_ini_block() {
    local entry key val out=""
    for entry in "${PHP_INI_OVERRIDES[@]}"; do
        key="${entry%%=*}"
        val="${entry#*=}"
        out+="php_admin_value[$key] = $val"$'\n'
    done
    printf '%s' "$out"
}

# A pool's listen socket is keyed by site name only
# (/run/php/<name>.sock — see templates/fpm-pool.conf.tmpl), not by PHP
# version, so a site whose php_version changed (re-provisioned, or now
# also on every `deploy` — see cmd_deploy.sh) would otherwise leave the
# OLD version's pool file behind, still running and still bound to that
# same socket path the NEW pool also wants. $1 name, $2 the version to
# KEEP — every other version's pool file for this site is removed.
remove_stale_fpm_pools() {
    local name="$1" keep_ver="$2"
    local pool_conf ver
    for pool_conf in /etc/php/*/fpm/pool.d/"$name".conf; do
        [[ -f "$pool_conf" ]] || continue
        ver="${pool_conf#/etc/php/}"
        ver="${ver%%/*}"
        [[ "$ver" == "$keep_ver" ]] && continue
        rm -f "$pool_conf"
        systemctl reload "php${ver}-fpm" 2>/dev/null || true
        log_info "removed stale FPM pool for $name under php$ver (now php$keep_ver)"
    done
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
    remove_stale_fpm_pools "$name" "$ver"
    local php_ini_block; php_ini_block="$(build_php_ini_block)"
    render_template "$PROVISIONER_DIR/templates/fpm-pool.conf.tmpl" "$pool_dir/$name.conf" \
        "NAME=$name" "POOL_USER=$pool_user" "POOL_GROUP=$pool_group" "MAX_CHILDREN=$max_children" \
        "PHP_INI_BLOCK=$php_ini_block"
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

# Site names (NAME_RE) allow hyphens; nginx variable names don't — this
# is the shared sanitizer for anything derived from $name used as one.
auth_var_name() { echo "${1//-/_}"; }

# Builds the `map $uri $auth_realm_<name><suffix> { ... }` block that
# lets auth_basic switch off per-request for AUTH_EXEMPT_PATHS[] entries
# (see build_auth_block). Empty string when there's nothing to exempt.
# `map` is http-context-only, not valid inside a server{} block —
# rendered above the server{} blocks in the same file, which works
# because sites-enabled/*.conf is itself `include`d at the http level
# already. $auth_realm_<name> is name-suffixed since every site's vhost
# file lives in the same included http context (an unsuffixed variable
# name would collide across sites) — $2 (suffix) disambiguates further,
# for a site's own custom-domain vhost, a SEPARATE file for the SAME
# name that would otherwise redeclare the identical map variable and
# fail `nginx -t` with a duplicate-variable error.
build_auth_map_block() {
    local name="$1" suffix="$2"; shift 2
    [[ "$#" -eq 0 ]] && return 0
    local out="map \$uri \$auth_realm_$(auth_var_name "$name")${suffix} {"$'\n'
    out+="    default \"Restricted\";"$'\n'
    local path
    for path in "$@"; do
        out+="    ~^${path} \"off\";"$'\n'
    done
    out+="}"$'\n'
    printf '%s' "$out"
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
#
# When AUTH_EXEMPT_PATHS[] is non-empty, auth_basic takes the map
# variable from build_auth_map_block instead of a literal "Restricted"
# — nginx allows a variable there, and treats the literal value "off" as
# turning auth off for that request. This has to be the map's variable,
# not a location-block trick: the app is a front-controller that
# rewrites every request to index.php via try_files, and that internal
# rewrite re-runs nginx's location search from the top of the server
# block, so a nested location inside an exempt-path location never
# actually gets used (confirmed the hard way — a per-path location
# wrapping its own \.php$ block looked right but 401'd anyway). auth_basic
# is an access-phase directive evaluated against $uri before try_files
# rewrites it, so the map sees the real, original request path. $3
# (suffix) must match whatever was passed to build_auth_map_block.
build_auth_block() {
    local name="$1" auth="$2" suffix="$3"
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
    local realm='"Restricted"'
    [[ "${#AUTH_EXEMPT_PATHS[@]}" -gt 0 ]] && realm="\$auth_realm_$(auth_var_name "$name")${suffix}"
    printf '    auth_basic %s;\n    auth_basic_user_file %s;' "$realm" "$htpasswd_file"
}

NGINX_EXTRA_DIR="/etc/nginx/ddeploy-extra"

# Hardcoded header set — no client-supplied header names or values.
# Off unless security_headers: true. `always` so they apply to error
# responses too. No HSTS: this fleet is often behind Cloudflare and
# custom domains start HTTP-only until the cert issues.
build_security_headers_block() {
    [[ "${SECURITY_HEADERS:-}" == "true" ]] || return 0
    cat <<'EOF'
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
EOF
}

# Prefix locations that 301/302. `^~` so they win over the front-controller
# regex. from/to/code already validated in parse_config.
build_redirects_block() {
    local line from to code
    for line in "${REDIRECTS[@]+"${REDIRECTS[@]}"}"; do
        from="${line%%$'\t'*}"
        to="${line#*$'\t'}"; to="${to%%$'\t'*}"
        code="${line##*$'\t'}"
        printf '    location ^~ %s { return %s %s; }\n' "$from" "$code" "$to"
    done
}

# Extensions build_static_cache_block treats as cacheable static assets.
# Shared with build_deny_php_block, which nests the identical rule
# inside each deny-php prefix — a top-level `^~` prefix location (what
# deny_php_in_uploads renders) is, once it's the longest match, never
# followed by nginx checking any top-level regex location at all, so
# without this, static_cache's own top-level `~*` block would be
# silently shadowed for exactly the subdirectory (uploads) most likely
# to hold cacheable assets. Safe to nest here (unlike auth_exempt_paths'
# now-abandoned nested-location attempt, see build_auth_block): this
# block's own try_files has no `/index.php` fallback, so a request under
# it is never internally rewritten, and nginx's location search is never
# re-run from the top mid-request the way it was for that case.
STATIC_CACHE_EXT_RE='\.(?:css|js|mjs|map|jpg|jpeg|gif|png|svg|webp|avif|ico|woff|woff2|ttf|otf|eot)$'

# Nested `deny all` for PHP under web-accessible upload (or explicit)
# prefixes. try_files =404 so a missing file does not fall through to
# index.php. Path `/` is rejected at parse time.
build_deny_php_block() {
    local path static_snippet=""
    if [[ -n "${STATIC_CACHE:-}" ]]; then
        static_snippet="$(cat <<EOF
        location ~* ${STATIC_CACHE_EXT_RE} {
            expires ${STATIC_CACHE};
            access_log off;
            try_files \$uri =404;
        }
EOF
)"
    fi
    for path in "${DENY_PHP_PATHS[@]+"${DENY_PHP_PATHS[@]}"}"; do
        path="${path%/}"
        # Prefix + trailing slash, not `location =`: nginx forbids nested
        # locations inside an exact match. `/uploads/x.php` is the
        # interesting request; `/uploads-other` does not match `/uploads/`.
        cat <<EOF
    location ^~ ${path}/ {
        location ~ \\.php\$ { deny all; }
${static_snippet}
        try_files \$uri \$uri/ =404;
    }
EOF
    done
}

# Static-asset expires. We own the extension regex; the client only
# picks the duration. `expires` sets Cache-Control, so this location
# does not use add_header (which would drop the server-level security
# headers nginx otherwise inherits).
build_static_cache_block() {
    local dur="${STATIC_CACHE:-}"
    [[ -n "$dur" ]] || return 0
    cat <<EOF
    location ~* ${STATIC_CACHE_EXT_RE} {
        expires $dur;
        access_log off;
        try_files \$uri =404;
    }
EOF
}

# Ops-owned extra, never from the client repo. Include only a regular
# root-owned file at the name-derived path (NAME_RE already validated
# the site name, so this cannot escape the directory). Missing = omit.
build_ops_extra_block() {
    local name="$1"
    local f="$NGINX_EXTRA_DIR/$name.conf"
    [[ -e "$f" ]] || return 0
    if [[ -L "$f" ]]; then
        log_warn "ignoring $f — must be a regular file, not a symlink"
        return 0
    fi
    if [[ ! -f "$f" ]]; then
        log_warn "ignoring $f — not a regular file"
        return 0
    fi
    local owner
    owner="$(stat -c '%u' "$f" 2>/dev/null || echo x)"
    if [[ "$owner" != "0" ]]; then
        log_warn "ignoring $f — not root-owned (uid $owner)"
        return 0
    fi
    printf '    include %s;\n' "$f"
}

# $4 (optional) client_max_body_size — defaults to the server-wide
# CLIENT_MAX_BODY_SIZE (provisioner.conf); callers pass the site's own
# CLIENT_MAX_BODY_SIZE_CONFIG override (.ddeploy/config.yaml) when set.
install_vhost() {
    local name="$1" root="$2" auth="$3" max_body_size="${4:-$CLIENT_MAX_BODY_SIZE}"; shift 4
    local server_names; server_names="$(build_server_names "$name" "$@")"
    local auth_map_block; auth_map_block="$(build_auth_map_block "$name" "" "${AUTH_EXEMPT_PATHS[@]}")"
    local auth_block; auth_block="$(build_auth_block "$name" "$auth" "")"
    local security_headers_block; security_headers_block="$(build_security_headers_block)"
    local redirects_block; redirects_block="$(build_redirects_block)"
    local deny_php_block; deny_php_block="$(build_deny_php_block)"
    local static_cache_block; static_cache_block="$(build_static_cache_block)"
    local ops_extra_block; ops_extra_block="$(build_ops_extra_block "$name")"

    render_template "$PROVISIONER_DIR/templates/vhost.conf.tmpl" "/etc/nginx/sites-available/$name.conf" \
        "NAME=$name" "SERVER_NAMES=$server_names" "ROOT=$root" "CERT_NAME=$BASE_DOMAIN" \
        "AUTH_BLOCK=$auth_block" "MAX_BODY_SIZE=$max_body_size" "AUTH_MAP_BLOCK=$auth_map_block" \
        "SECURITY_HEADERS_BLOCK=$security_headers_block" "REDIRECTS_BLOCK=$redirects_block" \
        "DENY_PHP_BLOCK=$deny_php_block" "STATIC_CACHE_BLOCK=$static_cache_block" \
        "OPS_EXTRA_BLOCK=$ops_extra_block"

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
