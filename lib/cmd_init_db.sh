#!/usr/bin/env bash
# `init-db` — set up this server as a dedicated MariaDB host that web
# servers connect to remotely (via DB_HOST/DB_ADMIN_CREDENTIALS in their
# own provisioner.conf). Idempotent. Run this instead of `init` on a
# server meant to hold only the database, not any sites.

cmd_init_db() {
    require_root
    load_db_conf

    log_info "== base packages =="
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server curl ufw

    log_info "== listen on all interfaces =="
    cat > /etc/mysql/mariadb.conf.d/99-remote.cnf <<'EOF'
[mysqld]
bind-address = 0.0.0.0
EOF

    systemctl enable --now mariadb
    systemctl restart mariadb

    log_info "== admin account =="
    local admin_user="ddeploy_admin" admin_pass
    if [[ -f "$DB_ADMIN_CREDENTIALS" ]]; then
        admin_pass="$(awk -F= '/^password/{print $2}' "$DB_ADMIN_CREDENTIALS")"
        log_info "reusing existing admin credentials at $DB_ADMIN_CREDENTIALS"
    else
        admin_pass="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)"
    fi

    local host
    for host in $DB_ALLOWED_HOSTS; do
        mysql <<SQL
CREATE USER IF NOT EXISTS '${admin_user}'@'${host}' IDENTIFIED BY '${admin_pass}';
ALTER USER '${admin_user}'@'${host}' IDENTIFIED BY '${admin_pass}';
GRANT ALL PRIVILEGES ON *.* TO '${admin_user}'@'${host}' WITH GRANT OPTION;
SQL
    done
    mysql -e "FLUSH PRIVILEGES;"

    mkdir -p "$(dirname "$DB_ADMIN_CREDENTIALS")"
    cat > "$DB_ADMIN_CREDENTIALS" <<EOF
[client]
user=$admin_user
password=$admin_pass
EOF
    chmod 600 "$DB_ADMIN_CREDENTIALS"
    chown root:root "$DB_ADMIN_CREDENTIALS"
    log_info "admin credentials at $DB_ADMIN_CREDENTIALS — copy this file to DB_ADMIN_CREDENTIALS on each web server"

    log_info "== firewall (ufw): 3306 from allowed hosts only, SSH open =="
    local ssh_port
    for ssh_port in $(detect_ssh_ports); do
        ufw allow "$ssh_port/tcp" comment 'ssh' >/dev/null
    done

    # DB_ALLOWED_HOSTS only changes when an operator edits provisioner.conf,
    # but every prior run rewrote all its "ddeploy-db"-tagged rules
    # unconditionally regardless — each ufw allow/delete is its own
    # individual iptables/nftables reload, so a no-op re-run still meant a
    # burst of back-to-back firewall reloads on every single init-db (see
    # the matching fix in lib/cloudflare.sh for the production lockout
    # this pattern is suspected to have caused there). Skip the rewrite
    # entirely when the configured hosts match what was applied last time.
    local cache="/etc/ddeploy/db-allowed-hosts.cache"
    local current; current="$(printf '%s\n' $DB_ALLOWED_HOSTS | sort)"
    local action="unchanged"
    if [[ ! -f "$cache" || "$current" != "$(cat "$cache")" ]]; then
        action="updated"
        # Replace any previously-added rules with the current list —
        # delete highest-numbered first so earlier deletions don't shift
        # the numbers of rules still queued for removal.
        local nums n
        # ufw pads single-digit rule numbers with a leading space (e.g.
        # "[ 1]", not "[1]") once there are 10+ rules to align columns —
        # match that optional space, or this never finds anything to
        # delete below 10. Both greps are wrapped with `|| true`: on a
        # fresh DB server (the normal first-init-db case) neither has
        # anything to match yet, and under set -o pipefail an unwrapped
        # no-match grep mid-pipeline aborts the rest of init-db the very
        # first time it runs.
        nums="$(ufw status numbered 2>/dev/null | { grep 'ddeploy-db' || true; } | { grep -oE '^\[[[:space:]]*[0-9]+\]' || true; } | tr -d '[] ' | sort -rn)"
        for n in $nums; do
            yes | ufw delete "$n" >/dev/null 2>&1 || true
        done
        for host in $DB_ALLOWED_HOSTS; do
            ufw allow from "$host" to any port 3306 proto tcp comment 'ddeploy-db' >/dev/null
        done
        mkdir -p "$(dirname "$cache")"
        printf '%s\n' "$current" > "$cache"
    fi
    ufw --force enable >/dev/null
    log_info "firewall: allowed hosts ($action), SSH open, default deny otherwise"

    log_info "init-db complete."
}
