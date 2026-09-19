#!/usr/bin/env bash
# A site's own domain(s) — .ddev/config.yaml's additional_fqdns, or the
# sidecar's matching field — as opposed to <name>.$BASE_DOMAIN, which the
# shared wildcard cert already covers. These aren't generally on the same
# Cloudflare account as $BASE_DOMAIN (or on Cloudflare at all), so each
# site's custom domains get their own certificate via HTTP-01 instead of
# the wildcard's DNS-01, issued the first time they're seen and left
# alone (renewal is certbot's timer, same as the wildcard) after that.
#
# Getting a fresh HTTP-01 cert needs nginx already serving the challenge
# path for the domain, which needs nginx config that references a cert
# that doesn't exist yet — so this installs an HTTP-only vhost first,
# requests the cert against that, then re-renders the vhost with TLS.

ACME_WEBROOT=/var/www/acme-challenge

# $1 name, $2 root, $3 auth ("true"/"false"), $4 client_max_body_size,
# remaining args: FQDNs. With no FQDNs, removes any existing
# custom-domain vhost for the site.
install_custom_domain_vhost() {
    local name="$1" root="$2" auth="$3" max_body_size="$4"; shift 4
    local fqdns=("$@")
    if [[ "${#fqdns[@]}" -eq 0 ]]; then
        remove_custom_domain_vhost "$name"
        return 0
    fi

    local server_names="${fqdns[*]}"
    local cert_name="${fqdns[0]}"
    local out="/etc/nginx/sites-available/$name-custom.conf"
    mkdir -p "$ACME_WEBROOT"

    if [[ ! -d "/etc/letsencrypt/live/$cert_name" ]]; then
        render_template "$PROVISIONER_DIR/templates/vhost-http-only.conf.tmpl" "$out" \
            "SERVER_NAMES=$server_names"
        ln -sf "$out" "/etc/nginx/sites-enabled/$name-custom.conf"
        nginx -t && systemctl reload nginx

        log_info "requesting certificate for ${fqdns[*]}"
        local certbot_domains=() f
        for f in "${fqdns[@]}"; do certbot_domains+=(-d "$f"); done
        if ! certbot certonly --webroot -w "$ACME_WEBROOT" --non-interactive --agree-tos \
                -m "$CERT_EMAIL" "${certbot_domains[@]}"; then
            log_warn "certificate request failed for ${fqdns[*]} — left the HTTP-only vhost in place (DNS for these domains must point at this server first); re-run provision to retry"
            return 1
        fi
    fi

    # "_custom" suffix: this vhost is a SEPARATE included file for the
    # same site name as the main vhost — without disambiguating, both
    # would declare the identical `map $uri $auth_realm_<name>`
    # variable in the same http context and nginx -t would fail on the
    # duplicate.
    local auth_map_block; auth_map_block="$(build_auth_map_block "$name" "_custom" "${AUTH_EXEMPT_PATHS[@]}")"
    local auth_block; auth_block="$(build_auth_block "$name" "$auth" "_custom")"
    render_template "$PROVISIONER_DIR/templates/vhost.conf.tmpl" "$out" \
        "NAME=$name" "SERVER_NAMES=$server_names" "ROOT=$root" "CERT_NAME=$cert_name" \
        "AUTH_BLOCK=$auth_block" "MAX_BODY_SIZE=${max_body_size:-$CLIENT_MAX_BODY_SIZE}" \
        "AUTH_MAP_BLOCK=$auth_map_block"
    ln -sf "$out" "/etc/nginx/sites-enabled/$name-custom.conf"
    nginx -t
    systemctl reload nginx
    log_info "installed custom-domain vhost for $name ($server_names, cert=$cert_name)"
}

remove_custom_domain_vhost() {
    local name="$1"
    local f="/etc/nginx/sites-available/$name-custom.conf"
    [[ -f "$f" ]] || return 0
    rm -f "/etc/nginx/sites-enabled/$name-custom.conf" "$f"
    nginx -t && systemctl reload nginx
    log_info "removed custom-domain vhost for $name"
}
