#!/usr/bin/env bash
# `init` — make a bare Ubuntu 24.04 (noble) server ready to serve sites.
# Idempotent: verifies and tops up rather than reinstalling blindly.
#
# Preconditions this does NOT set up for you: wildcard DNS already
# pointed at this server, a scoped Cloudflare API token already placed
# at $CF_CREDENTIALS, the shared git machine-user key already placed at
# $GIT_DEPLOY_KEY, and the `deploy` service user already existing.

cmd_init() {
    require_root
    load_conf

    log_info "== apt sources & base packages =="
    if ! grep -rq "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
        add-apt-repository -y ppa:ondrej/php
    fi
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        nginx mariadb-server certbot python3-certbot-dns-cloudflare software-properties-common \
        curl ufw

    log_info "== yq (must be the Go/mikefarah build, not the Python one) =="
    if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -qi mikefarah; then
        if command -v snap >/dev/null 2>&1; then
            snap install yq
        else
            die "snap unavailable — install the Go yq (mikefarah/yq) manually before continuing: https://github.com/mikefarah/yq#install"
        fi
    fi

    log_info "== baseline PHP versions: $BASELINE_PHP =="
    local ver
    for ver in $BASELINE_PHP; do
        ensure_php_installed "$ver"
    done

    log_info "== composer =="
    install_composer

    log_info "== sites root =="
    mkdir -p "$SITES_ROOT"
    if id -u deploy >/dev/null 2>&1; then
        chown deploy:deploy "$SITES_ROOT"
    else
        log_warn "service user 'deploy' not found — leaving $SITES_ROOT ownership as-is"
    fi

    log_info "== Cloudflare credentials =="
    [[ -f "$CF_CREDENTIALS" ]] || die "$CF_CREDENTIALS not found — place the scoped Cloudflare API token there before running init"
    chown root:root "$CF_CREDENTIALS"
    chmod 600 "$CF_CREDENTIALS"

    log_info "== git deploy key =="
    require_git_deploy_key
    chmod 600 "$GIT_DEPLOY_KEY"
    mkdir -p /etc/ssh
    # shellcheck disable=SC2086 # GIT_KNOWN_HOSTS_SEED is an intentional word list
    ssh-keyscan -t ed25519,rsa $GIT_KNOWN_HOSTS_SEED >> /etc/ssh/ssh_known_hosts 2>/dev/null
    sort -u -o /etc/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts

    log_info "== wildcard TLS cert for *.$BASE_DOMAIN =="
    if [[ -d "/etc/letsencrypt/live/$BASE_DOMAIN" ]]; then
        log_info "cert already present at /etc/letsencrypt/live/$BASE_DOMAIN — leaving as-is (certbot's own timer handles renewal)"
    else
        certbot certonly --non-interactive --agree-tos -m "$CERT_EMAIL" \
            --dns-cloudflare --dns-cloudflare-credentials "$CF_CREDENTIALS" \
            -d "*.$BASE_DOMAIN" -d "$BASE_DOMAIN"
    fi

    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh

    log_info "== nginx default site =="
    if [[ -e /etc/nginx/sites-enabled/default ]]; then
        rm -f /etc/nginx/sites-enabled/default
        log_info "disabled the stock default nginx site (per-site vhosts own the wildcard)"
    fi

    if [[ "$CLOUDFLARE_PROXIED" == "true" ]]; then
        configure_cloudflare_realip
    else
        log_info "CLOUDFLARE_PROXIED=false — skipping Cloudflare real-IP restoration"
    fi

    log_info "== services =="
    systemctl enable --now nginx mariadb
    for ver in $BASELINE_PHP; do
        systemctl enable --now "php${ver}-fpm"
    done
    systemctl enable --now certbot.timer 2>/dev/null || log_warn "no certbot.timer unit found — confirm renewal is scheduled some other way"

    nginx -t && systemctl reload nginx

    if [[ "$CLOUDFLARE_PROXIED" == "true" ]]; then
        configure_cloudflare_firewall
    else
        log_info "CLOUDFLARE_PROXIED=false — skipping Cloudflare-only firewall (SSH still allowed via ufw if you enable it yourself)"
    fi

    log_info "init complete."
}
