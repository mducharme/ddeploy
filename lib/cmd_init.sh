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

    # Fully unattended from here on — no prompt in this function ever
    # expects real input. Closing stdin isn't just belt-and-suspenders:
    # confirmed in a real Ubuntu 24.04 container that apt-get installing
    # a package that owns a running service (nginx, mariadb-server,
    # php-fpm) hangs indefinitely waiting on a terminal read whenever
    # run in the foreground of a real SSH session, even with
    # DEBIAN_FRONTEND=noninteractive AND NEEDRESTART_MODE=a both set —
    # something downstream (invoke-rc.d/needrestart/polkit, the exact
    # culprit varied by environment) still probes the controlling
    # terminal. Redirecting stdin from /dev/null makes that probe hit
    # EOF immediately instead of blocking, which is what actually fixed
    # it in testing; the env vars alone did not.
    exec < /dev/null

    log_info "== apt sources & base packages =="
    # add-apt-repository itself comes from software-properties-common,
    # which a minimal base image (a bare Docker image; some providers'
    # "minimal" cloud images too) doesn't have preinstalled — without
    # this, the ondrej/php PPA step below fails on the very first init
    # with "add-apt-repository: command not found" before anything else
    # gets installed.
    if ! command -v add-apt-repository >/dev/null 2>&1; then
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common
    fi
    if ! grep -rq "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
        add-apt-repository -y ppa:ondrej/php
    fi
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        nginx mariadb-server certbot python3-certbot-dns-cloudflare software-properties-common \
        curl ufw apache2-utils python3 cron

    log_info "== yq (must be the Go/mikefarah build, not the Python one) =="
    local yq_path
    yq_path="$(command -v yq 2>/dev/null || true)"
    if [[ -z "$yq_path" ]] || ! yq --version 2>&1 | grep -qi mikefarah || [[ "$yq_path" == /snap/* ]]; then
        # A pinned binary, not `snap install yq` (what an earlier version
        # of this script used) — snap packages run under strict AppArmor
        # confinement by default, and root does NOT bypass that the way
        # it bypasses ordinary file permissions. Under sudo (without -H),
        # $HOME becomes /root, so a snap-confined yq can't read anything
        # under SITES_ROOT — every yq call in this tool fails with
        # "permission denied" on a perfectly ordinary, readable file
        # (confirmed in production, not hypothetical). Replace a
        # snap-installed yq left by a previous run too, not just a
        # missing one.
        if [[ "$yq_path" == /snap/* ]]; then
            log_warn "found a snap-installed yq on PATH ($yq_path) — replacing it with a pinned binary; snap's confinement blocks it from reading SITES_ROOT under sudo"
            snap remove yq >/dev/null 2>&1 || true
        fi
        curl -fsSL -o /usr/local/bin/yq \
            "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture)"
        chmod +x /usr/local/bin/yq
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
    ensure_traversable "$SITES_ROOT"

    log_info "== persistent store =="
    mkdir -p "$PERSISTENT_ROOT"
    if id -u deploy >/dev/null 2>&1; then
        chown deploy:deploy "$PERSISTENT_ROOT"
    else
        log_warn "service user 'deploy' not found — leaving $PERSISTENT_ROOT ownership as-is"
    fi
    ensure_traversable "$PERSISTENT_ROOT"

    log_info "== Cloudflare credentials =="
    [[ -f "$CF_CREDENTIALS" ]] || die "$CF_CREDENTIALS not found — place the scoped Cloudflare API token there before running init"
    chown root:root "$CF_CREDENTIALS"
    chmod 600 "$CF_CREDENTIALS"

    log_info "== git deploy key =="
    require_git_deploy_key
    chown root:root "$GIT_DEPLOY_KEY"
    chmod 600 "$GIT_DEPLOY_KEY"
    mkdir -p /etc/ssh
    # shellcheck disable=SC2086 # GIT_KNOWN_HOSTS_SEED is an intentional word list
    ssh-keyscan -t ed25519,rsa $GIT_KNOWN_HOSTS_SEED >> /etc/ssh/ssh_known_hosts 2>/dev/null
    sort -u -o /etc/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts

    log_info "== basic auth default credentials =="
    mkdir -p "$(dirname "$BASIC_AUTH_CREDENTIALS")"
    if [[ -f "$BASIC_AUTH_CREDENTIALS" ]]; then
        log_info "default basic-auth credentials already exist at $BASIC_AUTH_CREDENTIALS — leaving as-is"
    else
        local auth_pass
        auth_pass="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16)"
        htpasswd -bc "$BASIC_AUTH_CREDENTIALS" preview "$auth_pass"
        chown root:www-data "$BASIC_AUTH_CREDENTIALS"
        chmod 640 "$BASIC_AUTH_CREDENTIALS"
        log_info "generated default basic-auth credentials: user=preview password=$auth_pass (saved at $BASIC_AUTH_CREDENTIALS — this is logged only this once)"
    fi

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
    mkdir -p "$NGINX_EXTRA_DIR"
    chmod 755 "$NGINX_EXTRA_DIR"
    chown root:root "$NGINX_EXTRA_DIR"

    if [[ "$CLOUDFLARE_PROXIED" == "true" ]]; then
        configure_cloudflare_realip
    else
        log_info "CLOUDFLARE_PROXIED=false — skipping Cloudflare real-IP restoration"
    fi

    log_info "== services =="
    systemctl enable --now nginx mariadb cron
    for ver in $BASELINE_PHP; do
        systemctl enable --now "php${ver}-fpm"
    done
    systemctl enable --now certbot.timer 2>/dev/null || log_warn "no certbot.timer unit found — confirm renewal is scheduled some other way"

    log_info "== git webhook =="
    if [[ "$WEBHOOK_ENABLED" == "true" ]]; then
        command -v python3 >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y python3
        install_webhook
    else
        disable_webhook
        log_info "WEBHOOK_ENABLED=false — skipping git webhook listener"
    fi

    nginx -t && systemctl reload nginx

    if [[ "$CLOUDFLARE_PROXIED" == "true" ]]; then
        configure_cloudflare_firewall
    else
        log_info "CLOUDFLARE_PROXIED=false — skipping Cloudflare-only firewall (SSH still allowed via ufw if you enable it yourself)"
    fi

    log_info "== backups =="
    rm -f /etc/cron.d/ddeploy-backup   # old (pre-split) cron filename, if left over from an earlier init

    if [[ "$BACKUP_ENABLED" == "true" || "$DB_BACKUP_ENABLED" == "true" ]]; then
        command -v rclone >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y rclone
        require_backup_credentials
        chmod 600 "$BACKUP_CREDENTIALS"
    fi

    if [[ "$BACKUP_ENABLED" == "true" ]]; then
        cat > /etc/cron.d/ddeploy-backup-uploads <<EOF
$BACKUP_SCHEDULE root $PROVISIONER_DIR/provision.sh backup-uploads >> $LOG_DIR/backup-uploads.log 2>&1
EOF
        chmod 644 /etc/cron.d/ddeploy-backup-uploads
        log_info "cron: backup-uploads runs on schedule '$BACKUP_SCHEDULE' as root, via /etc/cron.d/ddeploy-backup-uploads — this is NOT in 'crontab -l' for any user, that only shows per-user crontabs"
    else
        rm -f /etc/cron.d/ddeploy-backup-uploads
        log_info "BACKUP_ENABLED=false — skipping uploads backup cron"
    fi

    if [[ "$DB_BACKUP_ENABLED" == "true" ]]; then
        cat > /etc/cron.d/ddeploy-backup-database <<EOF
$DB_BACKUP_SCHEDULE root $PROVISIONER_DIR/provision.sh backup-database >> $LOG_DIR/backup-database.log 2>&1
EOF
        chmod 644 /etc/cron.d/ddeploy-backup-database
        log_info "cron: backup-database runs on schedule '$DB_BACKUP_SCHEDULE' as root, via /etc/cron.d/ddeploy-backup-database"
    else
        rm -f /etc/cron.d/ddeploy-backup-database
        log_info "DB_BACKUP_ENABLED=false — skipping database backup cron"
    fi

    if [[ "$PREVIEW_PRUNE_ENABLED" == "true" ]]; then
        cat > /etc/cron.d/ddeploy-prune-previews <<EOF
$PREVIEW_PRUNE_SCHEDULE root $PROVISIONER_DIR/provision.sh prune-previews >> $LOG_DIR/prune-previews.log 2>&1
EOF
        chmod 644 /etc/cron.d/ddeploy-prune-previews
        log_info "cron: prune-previews runs on schedule '$PREVIEW_PRUNE_SCHEDULE' as root, via /etc/cron.d/ddeploy-prune-previews"
    else
        rm -f /etc/cron.d/ddeploy-prune-previews
        log_info "PREVIEW_PRUNE_ENABLED=false — skipping preview-prune cron"
    fi

    log_info "init complete."
}
