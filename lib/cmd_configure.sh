#!/usr/bin/env bash
# `configure` — interactive wizard that creates (or updates) provisioner.conf
# from provisioner.example.conf. Both provisioner.conf and manifest are
# per-server and gitignored (README "Quickstart") — a fresh clone has
# neither, so this is the normal first thing to run, either directly or
# via ./install.sh. Re-running it later only touches the fields below;
# everything else already in provisioner.conf is left alone.

usage_configure() {
    cat <<'EOF'
usage: provision.sh configure

Creates ./provisioner.conf from provisioner.example.conf (if it doesn't
exist yet) and interactively sets the fields provision.sh cannot start
without: BASE_DOMAIN, SITES_ROOT, CF_CREDENTIALS, CERT_EMAIL,
BASELINE_PHP, DEFAULT_PHP, GIT_DEPLOY_KEY. Press enter to keep the
current/example value for any field. Everything else in provisioner.conf
(backups, webhooks, remote DB, ...) is left at its example default —
edit those by hand afterward if you need them.

Does not place the CF_CREDENTIALS/GIT_DEPLOY_KEY files themselves (those
are secrets); it only records where you'll put them.
EOF
}

cmd_configure() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_configure; return 0; }

    local target="$PROVISIONER_DIR/provisioner.conf"
    local example="$PROVISIONER_DIR/provisioner.example.conf"
    [[ -f "$example" ]] || die "missing $example — is this a full ddeploy checkout?"

    if [[ -f "$target" ]]; then
        log_info "provisioner.conf already exists — updating the fields below in place; everything else is left alone"
    else
        cp "$example" "$target"
        log_info "created provisioner.conf from provisioner.example.conf"
    fi

    echo "Setting up provisioner.conf for this server. Press enter to keep the value in [brackets]."
    echo

    configure_field "$target" BASE_DOMAIN "this server's wildcard root, e.g. staging.example.com"
    configure_field "$target" SITES_ROOT "where site checkouts live"
    configure_field "$target" CF_CREDENTIALS "Cloudflare API token file (place it here yourself, chmod 600)"
    configure_field "$target" CERT_EMAIL "email for Let's Encrypt notices"
    configure_field "$target" BASELINE_PHP "space-separated PHP versions init pre-installs, e.g. \"8.2 8.3\""
    configure_field "$target" DEFAULT_PHP "PHP version used when a new site doesn't specify one"
    configure_field "$target" GIT_DEPLOY_KEY "shared machine-user SSH private key (place it here yourself, chmod 600)"

    echo
    log_info "wrote $target"
    log_info "next: place a Cloudflare token at CF_CREDENTIALS and the shared git key at GIT_DEPLOY_KEY (chmod 600 each), review the rest of provisioner.conf, then 'sudo ./provision.sh init'"

    if [[ ! -f "$PROVISIONER_DIR/manifest" ]]; then
        log_info "./manifest doesn't exist yet — copy manifest.example to manifest if you'll use provision-all/deploy-all"
    fi
}

# $1 target file  $2 KEY (must already appear as KEY="...") $3 prompt text
configure_field() {
    local target="$1" key="$2" desc="$3"
    local current
    current="$(sed -nE "s/^${key}=\"([^\"]*)\".*/\1/p" "$target" | head -1)"
    local input
    read -rp "$key ($desc) [$current]: " input
    [[ -n "$input" ]] || input="$current"
    [[ "$input" != *'"'* ]] || die "$key: value cannot contain a double quote"
    local tmp; tmp="$(mktemp)"
    awk -v k="$key" -v v="$input" '
        BEGIN { pat = "^" k "=\"" }
        $0 ~ pat {
            rest = $0
            sub(pat "[^\"]*\"", "", rest)
            print k "=\"" v "\"" rest
            next
        }
        { print }
    ' "$target" > "$tmp"
    mv "$tmp" "$target"
}
