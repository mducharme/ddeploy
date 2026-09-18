#!/usr/bin/env bash
# Cloudflare-proxy setup, gated by CLOUDFLARE_PROXIED (provisioner.conf):
# restoring the real visitor IP in nginx/PHP, and firewalling the origin
# down to Cloudflare's own ranges (+ SSH) so the proxy can't be bypassed
# by hitting the server's IP directly. Both use Cloudflare's published
# ranges, refetched on every `init` run since they change occasionally.

fetch_cloudflare_ranges() {
    local url
    for url in https://www.cloudflare.com/ips-v4 https://www.cloudflare.com/ips-v6; do
        curl -fsS "$url" 2>/dev/null
        echo   # guarantee a newline between lists even if a response body lacks a trailing one
    done | grep -v '^$'
}

configure_cloudflare_realip() {
    log_info "== Cloudflare real-IP restoration =="
    local ranges; mapfile -t ranges < <(fetch_cloudflare_ranges)
    if [[ "${#ranges[@]}" -eq 0 ]]; then
        log_warn "couldn't fetch Cloudflare IP ranges — skipping real-IP restoration (re-run init to retry)"
        return
    fi

    local conf=/etc/nginx/conf.d/cloudflare-realip.conf
    local cidr
    {
        for cidr in "${ranges[@]}"; do
            echo "set_real_ip_from $cidr;"
        done
        echo "real_ip_header CF-Connecting-IP;"
        echo "real_ip_recursive on;"
    } > "$conf"
    log_info "wrote $conf (${#ranges[@]} Cloudflare ranges)"
}

configure_cloudflare_firewall() {
    log_info "== firewall (ufw): 80/443 from Cloudflare only, SSH open =="
    command -v ufw >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y ufw

    local ranges; mapfile -t ranges < <(fetch_cloudflare_ranges)
    if [[ "${#ranges[@]}" -eq 0 ]]; then
        log_warn "couldn't fetch Cloudflare IP ranges — leaving firewall rules untouched (re-run init to retry)"
        return
    fi

    local ssh_port
    for ssh_port in $(detect_ssh_ports); do
        ufw allow "$ssh_port/tcp" comment 'ssh' >/dev/null
    done

    # Cloudflare's ranges rarely change, but every prior run rewrote all
    # ~20+ "cloudflare"-tagged rules unconditionally regardless — each ufw
    # allow/delete is its own individual iptables/nftables reload, so even
    # a no-op re-run meant ~50 back-to-back firewall reloads on every
    # single `init`. That churn is the suspected cause of a real,
    # recurring SSH lockout on a production box that only a full reboot
    # cleared (rules looked correct via `ufw status`, but new connections
    # still couldn't get through — consistent with a kernel-level
    # netfilter hiccup during rapid rule churn, not a logical
    # misconfiguration). Skip the rewrite entirely when the fetched
    # ranges match what was applied last time.
    local cache="/etc/ddeploy/cloudflare-ranges.cache"
    local current; current="$(printf '%s\n' "${ranges[@]}" | sort)"
    local action="unchanged"
    if [[ ! -f "$cache" || "$current" != "$(cat "$cache")" ]]; then
        action="updated"
        # Replace any previously-added Cloudflare rules with the current
        # list — delete highest-numbered first so earlier deletions don't
        # shift the numbers of rules still queued for removal.
        local nums n
        # ufw pads single-digit rule numbers with a leading space (e.g.
        # "[ 1]", not "[1]") once there are 10+ rules to align columns —
        # match that optional space, or this never finds anything to
        # delete below 10. Both greps are wrapped with `|| true`: on a
        # fresh server (the normal first-init case) neither has anything
        # to match yet, and under set -o pipefail an unwrapped no-match
        # grep mid-pipeline aborts this whole function — and everything
        # after it in `init` — the very first time it runs.
        nums="$(ufw status numbered 2>/dev/null | { grep 'cloudflare' || true; } | { grep -oE '^\[[[:space:]]*[0-9]+\]' || true; } | tr -d '[] ' | sort -rn)"
        for n in $nums; do
            yes | ufw delete "$n" >/dev/null 2>&1 || true
        done

        local cidr
        for cidr in "${ranges[@]}"; do
            ufw allow from "$cidr" to any port 80,443 proto tcp comment 'cloudflare' >/dev/null
        done

        mkdir -p "$(dirname "$cache")"
        printf '%s\n' "$current" > "$cache"
    fi

    ufw --force enable >/dev/null
    log_info "firewall: ${#ranges[@]} Cloudflare ranges ($action) allowed on 80/443, SSH open, default deny otherwise"
}
