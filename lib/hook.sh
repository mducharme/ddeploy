#!/usr/bin/env bash
# Git-forge webhook: install the unprivileged listener + root worker, and
# process spooled jobs. See hook/listener.py and README "Deploy on git push".

WEBHOOK_USER="ddeploy-hook"
WEBHOOK_QUEUE_ROOT="/var/lib/ddeploy/queue"
WEBHOOK_LISTEN_DEFAULT="127.0.0.1:8787"
WEBHOOK_SECRET_DEFAULT="/etc/ddeploy/webhook.secret"

hook_listener() { echo "$PROVISIONER_DIR/hook/listener.py"; }

canonicalize_git_url() {
    python3 "$(hook_listener)" --canonicalize "$1"
}

# Prints provisioned site names whose origin URL canonicalizes to any of
# the remaining args (already-canonical host/path strings from a job).
# Skips unreadable remotes rather than dying — an org webhook fires for
# every repo and most will not match anything on this box.
matching_sites_for_urls() {
    local -a want=("$@")
    local site_path name origin canon w
    for site_path in "$SITES_ROOT"/*/; do
        [[ -d "$site_path" ]] || continue
        name="$(basename "$site_path")"
        is_provisioned "$name" || continue
        origin="$(git -C "$(site_dir "$name")" remote get-url origin 2>/dev/null || true)"
        [[ -n "$origin" ]] || continue
        canon="$(canonicalize_git_url "$origin")"
        [[ -n "$canon" ]] || continue
        for w in "${want[@]}"; do
            if [[ "$canon" == "$w" ]]; then
                printf '%s\n' "$name"
                break
            fi
        done
    done
}

site_head_branch() {
    git -C "$(site_dir "$1")" rev-parse --abbrev-ref HEAD 2>/dev/null || true
}

# $1 site name — serialize webhook-driven deploys of the same site.
with_site_lock() {
    local name="$1"; shift
    local lock_dir="/var/lib/ddeploy/locks"
    mkdir -p "$lock_dir"
    flock "$lock_dir/$name.lock" "$@"
}

install_webhook() {
    local hostname="${WEBHOOK_HOSTNAME:-hooks.$BASE_DOMAIN}"
    local secret_path="${WEBHOOK_SECRET:-$WEBHOOK_SECRET_DEFAULT}"
    local secret_bb="${WEBHOOK_SECRET_BITBUCKET:-}"
    local listen="${WEBHOOK_LISTEN:-$WEBHOOK_LISTEN_DEFAULT}"
    local spool="$WEBHOOK_QUEUE_ROOT/new"

    if ! id -u "$WEBHOOK_USER" >/dev/null 2>&1; then
        useradd --system --no-create-home --home-dir /var/lib/ddeploy --shell /usr/sbin/nologin "$WEBHOOK_USER"
        log_info "created system user $WEBHOOK_USER"
    fi

    mkdir -p "$spool" "$WEBHOOK_QUEUE_ROOT/failed" /var/lib/ddeploy/locks /etc/ddeploy
    chown root:"$WEBHOOK_USER" /var/lib/ddeploy "$WEBHOOK_QUEUE_ROOT" "$spool"
    chmod 750 /var/lib/ddeploy
    chmod 2770 "$WEBHOOK_QUEUE_ROOT" "$spool"
    chmod 700 "$WEBHOOK_QUEUE_ROOT/failed" /var/lib/ddeploy/locks

    if [[ ! -f "$secret_path" ]]; then
        mkdir -p "$(dirname "$secret_path")"
        openssl rand -hex 32 > "$secret_path"
        log_info "generated webhook HMAC secret at $secret_path (this is not logged)"
    fi
    chown root:"$WEBHOOK_USER" "$secret_path"
    chmod 640 "$secret_path"
    if [[ -n "$secret_bb" && -f "$secret_bb" ]]; then
        chown root:"$WEBHOOK_USER" "$secret_bb"
        chmod 640 "$secret_bb"
    fi

    cat > /etc/ddeploy/hook.env <<EOF
DDEPLOY_HOOK_SECRET=$secret_path
DDEPLOY_HOOK_SECRET_BITBUCKET=$secret_bb
DDEPLOY_HOOK_LISTEN=$listen
DDEPLOY_HOOK_SPOOL=$spool
EOF
    chmod 640 /etc/ddeploy/hook.env
    chown root:"$WEBHOOK_USER" /etc/ddeploy/hook.env

    local port="${listen##*:}"
    render_template "$PROVISIONER_DIR/templates/hook-vhost.conf.tmpl" /etc/nginx/sites-available/ddeploy-hook.conf \
        "HOSTNAME=$hostname" "CERT_NAME=$BASE_DOMAIN" "PORT=$port"
    ln -sf /etc/nginx/sites-available/ddeploy-hook.conf /etc/nginx/sites-enabled/ddeploy-hook.conf

    # Copy, don't point systemd at the git checkout: the listener runs as
    # an unprivileged user that should not need to traverse PROVISIONER_DIR.
    mkdir -p /usr/local/lib/ddeploy
    cp "$(hook_listener)" /usr/local/lib/ddeploy/listener.py
    chown root:"$WEBHOOK_USER" /usr/local/lib/ddeploy/listener.py
    chmod 640 /usr/local/lib/ddeploy/listener.py

    cat > /etc/systemd/system/ddeploy-hook.service <<EOF
[Unit]
Description=ddeploy git webhook listener
After=network.target

[Service]
Type=simple
User=$WEBHOOK_USER
Group=$WEBHOOK_USER
EnvironmentFile=/etc/ddeploy/hook.env
ExecStart=/usr/bin/python3 /usr/local/lib/ddeploy/listener.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/ddeploy-hook-worker.service <<EOF
[Unit]
Description=ddeploy git webhook worker

[Service]
Type=oneshot
ExecStart=$PROVISIONER_DIR/provision.sh hook-worker
EOF

    cat > /etc/systemd/system/ddeploy-hook-worker.path <<EOF
[Unit]
Description=ddeploy git webhook queue watcher

[Path]
DirectoryNotEmpty=$spool

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ddeploy-hook.service ddeploy-hook-worker.path
    # restart: re-init copies a newer listener.py; enable --now would
    # leave the old process running the previous copy.
    systemctl restart ddeploy-hook.service
    systemctl start ddeploy-hook-worker.path
    log_info "webhook listening on $listen, vhost $hostname (POST /github and /bitbucket)"
}

disable_webhook() {
    systemctl disable --now ddeploy-hook.service ddeploy-hook-worker.path 2>/dev/null || true
    rm -f /etc/nginx/sites-enabled/ddeploy-hook.conf /etc/nginx/sites-available/ddeploy-hook.conf
}
