#!/usr/bin/env bash
# `configure` — interactive wizard that creates (or updates) provisioner.conf
# from provisioner.example.conf. Both provisioner.conf and manifest are
# per-server and gitignored (README "Quickstart") — a fresh clone has
# neither, so this is the normal first thing to run, either directly or
# via ./install.sh. Re-running it later only touches the fields below;
# everything else already in provisioner.conf is left alone.
#
# `configure backups` / `configure webhook` are the same idea for two
# optional feature areas that each need both a provisioner.conf edit and
# a credentials file — see README "Backups" / "Deploy on git push".

usage_configure() {
    cat <<'EOF'
usage: provision.sh configure [backups|webhook]

(no argument) Creates ./provisioner.conf from provisioner.example.conf
(if it doesn't exist yet) and interactively sets the fields provision.sh
cannot start without: BASE_DOMAIN, SITES_ROOT, CF_CREDENTIALS,
CERT_EMAIL, BASELINE_PHP, DEFAULT_PHP, GIT_DEPLOY_KEY. Press enter to
keep the current/example value for any field. Does not place the
CF_CREDENTIALS/GIT_DEPLOY_KEY files themselves (those are secrets); it
only records where you'll put them.

backups   Walks through object storage credentials (S3, DigitalOcean
          Spaces, or any other S3-compatible endpoint) for
          backup-uploads/backup-database, writes BACKUP_CREDENTIALS, and
          turns BACKUP_ENABLED/DB_BACKUP_ENABLED on.

webhook   Turns WEBHOOK_ENABLED on, generates the HMAC secret, and offers
          to register the webhook itself via the GitHub/Bitbucket API
          (prompts for a token/app-password, used once, never saved) —
          neither forge's own UI exposes org/workspace-level webhook
          creation the same way. Optionally sets up
          PREVIEW_COMMENT_CREDENTIALS (PR preview comments) too.

All three are safe to re-run later to change settings.
EOF
}

cmd_configure() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_configure; return 0; }
    case "${1:-}" in
        backups) cmd_configure_backups ;;
        webhook) cmd_configure_webhook ;;
        "") cmd_configure_core ;;
        *) usage_configure; die "unknown configure target: $1" ;;
    esac
}

require_provisioner_conf() {
    [[ -f "$PROVISIONER_DIR/provisioner.conf" ]] \
        || die "no provisioner.conf yet — run 'provision.sh configure' first"
}

cmd_configure_core() {
    # provisioner.conf is `source`d, not parsed (lib/common.sh) — whoever
    # can write it gets arbitrary code exec on the next command that
    # reads it. It lives inside $PROVISIONER_DIR, which is root-owned
    # (see bootstrap.sh) precisely so a lower-trust actor (CI SSH, a
    # webhook) can't rewrite what root-triggered cron/systemd units
    # execute — configure has to run as root too, or it simply couldn't
    # write here anymore.
    require_root
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

cmd_configure_backups() {
    require_root
    require_provisioner_conf
    local target="$PROVISIONER_DIR/provisioner.conf"

    echo "Setting up object storage backups (uploads + database)."
    echo "Both share one set of credentials and one bucket, at <bucket>/<site>/... and <bucket>/<site>/db/..."
    echo
    echo "  1) DigitalOcean Spaces"
    echo "  2) AWS S3"
    echo "  3) Other S3-compatible (MinIO, Backblaze B2's S3 API, Wasabi, ...)"
    local choice; read -rp "Provider [1]: " choice
    [[ -n "$choice" ]] || choice=1

    local hint=""
    case "$choice" in
        1) hint="e.g. https://nyc3.digitaloceanspaces.com — the region is shown on the Space's own settings page (nyc3/sfo3/ams3/sgp1/fra1/...)" ;;
        2) hint="e.g. https://s3.us-east-1.amazonaws.com — the region the bucket was created in" ;;
        *) hint="your provider's S3-compatible endpoint URL" ;;
    esac
    echo "Endpoint hint: $hint"

    local endpoint bucket access_key secret_key cred_path
    endpoint="$(prompt_required "BACKUP_ENDPOINT")"
    bucket="$(prompt_required "Bucket/space name")"
    access_key="$(prompt_required "Access key")"
    secret_key="$(prompt_secret "Secret key")"
    cred_path="$(prompt_value "Write credentials to" "/etc/ddeploy/backup-credentials.env")"

    # Stage first, test, only move into place on success (or on an
    # explicit "write anyway") — a typo'd key silently written and not
    # caught until the cron job fails days later is worse than asking
    # once here.
    local staged; staged="$(mktemp)"
    cat > "$staged" <<EOF
BACKUP_ENDPOINT="$endpoint"
BACKUP_ACCESS_KEY="$access_key"
BACKUP_SECRET_KEY="$secret_key"
EOF
    chmod 600 "$staged"

    if ! command -v rclone >/dev/null 2>&1; then
        log_warn "rclone isn't installed yet (that's 'init's job) — skipping the credential test; verify later with 'backup-uploads'/'backup-database'"
    else
        log_info "testing credentials against '$bucket'..."
        local test_err; test_err="$(mktemp)"
        local test_ok=1
        (
            BACKUP_CREDENTIALS="$staged" BACKUP_BUCKET="$bucket"
            remote="$(backup_remote_spec)"
            timeout 15 rclone lsd "$remote" >/dev/null 2>"$test_err"
        ) || test_ok=0
        if [[ "$test_ok" -eq 1 ]]; then
            log_info "credentials OK — '$bucket' is reachable and listable"
            rm -f "$test_err"
        else
            log_warn "could not list '$bucket' with these credentials:"
            sed 's/^/  /' "$test_err" >&2
            rm -f "$test_err"
            local yn
            read -rp "Write them anyway? (the bucket may just not exist yet) [y/N]: " yn
            if [[ ! "$yn" =~ ^[Yy] ]]; then
                rm -f "$staged"
                die "aborted — nothing written"
            fi
        fi
    fi

    mkdir -p "$(dirname "$cred_path")"
    mv "$staged" "$cred_path"
    chmod 600 "$cred_path"
    log_info "wrote $cred_path (chmod 600)"

    set_conf_value "$target" BACKUP_CREDENTIALS "$cred_path"
    set_conf_value "$target" BACKUP_BUCKET "$bucket"

    local yn
    read -rp "Enable uploads backup (BACKUP_ENABLED)? [Y/n]: " yn
    set_conf_value "$target" BACKUP_ENABLED "$([[ "$yn" =~ ^[Nn] ]] && echo false || echo true)"
    read -rp "Enable database backup (DB_BACKUP_ENABLED)? [Y/n]: " yn
    set_conf_value "$target" DB_BACKUP_ENABLED "$([[ "$yn" =~ ^[Nn] ]] && echo false || echo true)"

    echo
    log_info "wrote $target"
    log_info "next: sudo ./provision.sh init (installs rclone + the backup cron entries), then a project needs upload_dirs: declared (.ddev/config.yaml or --upload-dirs) before backup-uploads does anything for it — backup-database needs no per-project config"
    log_info "test on demand any time: sudo ./provision.sh backup-uploads <name> / backup-database <name>"
}

cmd_configure_webhook() {
    require_root
    require_provisioner_conf
    local target="$PROVISIONER_DIR/provisioner.conf"

    set_conf_value "$target" WEBHOOK_ENABLED "true"
    local hostname; hostname="$(get_conf_value "$target" WEBHOOK_HOSTNAME)"
    local base_domain; base_domain="$(get_conf_value "$target" BASE_DOMAIN)"
    [[ -n "$base_domain" ]] || die "BASE_DOMAIN isn't set yet — run 'provision.sh configure' first"
    [[ -n "$hostname" ]] || hostname="hooks.${base_domain}"
    local secret_path; secret_path="$(get_conf_value "$target" WEBHOOK_SECRET)"
    [[ -n "$secret_path" ]] || secret_path="/etc/ddeploy/webhook.secret"

    # Generated here (not left to `init`) so registration below has a
    # real secret to send even before `init` has ever run. `init`'s own
    # install_webhook unconditionally chowns/chmods this file to
    # root:ddeploy-hook afterward regardless of who created it, so
    # nothing needs fixing up later.
    if [[ ! -f "$secret_path" ]]; then
        mkdir -p "$(dirname "$secret_path")"
        ( umask 077; openssl rand -hex 32 > "$secret_path" )
        log_info "generated webhook HMAC secret at $secret_path (not logged)"
    fi
    local secret; secret="$(<"$secret_path")"

    log_info "set WEBHOOK_ENABLED=true in $target"
    echo

    local yn
    read -rp "Register this webhook now via the GitHub/Bitbucket API? Neither forge exposes org/workspace-level webhook creation in a way this tool can drive except the API (GitHub's UI works too, but the API is used for both here). [y/N]: " yn
    if [[ "$yn" =~ ^[Yy] ]]; then
        read -rp "  Register on GitHub (org webhook)? [y/N]: " yn
        if [[ "$yn" =~ ^[Yy] ]]; then
            local org; org="$(prompt_required "  GitHub org (exact slug, e.g. youragency)")"
            [[ "$org" =~ ^[A-Za-z0-9_-]+$ ]] || die "GitHub org: unexpected characters in '$org'"
            register_webhook github "$org" "https://$hostname/github" "$secret"
        fi
        read -rp "  Register on Bitbucket (workspace webhook)? [y/N]: " yn
        if [[ "$yn" =~ ^[Yy] ]]; then
            local workspace; workspace="$(prompt_required "  Bitbucket workspace slug")"
            [[ "$workspace" =~ ^[A-Za-z0-9_-]+$ ]] || die "Bitbucket workspace: unexpected characters in '$workspace'"
            register_webhook bitbucket "$workspace" "https://$hostname/bitbucket" "$secret"
        fi
    else
        echo "Register it yourself later — see README \"Deploy on git push\" for the exact API calls,"
        echo "or re-run 'provision.sh configure webhook' when you're ready."
    fi
    echo

    read -rp "Set up PR preview comments now too (posts a comment with the preview URL)? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy] ]]; then
        echo "One or both — leave either side blank to skip it."
        # Each of these is only assigned inside a conditional below (e.g.
        # gh_api only if gh_token is given) — under set -u, a `local` that
        # never gets assigned is still unbound when read, even by `[[ -n
        # ]]`, so every one needs an explicit empty default here.
        local gh_token="" gh_api="" bb_user="" bb_pass="" bb_api="" cred_path=""
        gh_token="$(prompt_value "GitHub token (repo:status or fine-grained Pull requests: Read and write)" "")"
        if [[ -n "$gh_token" ]]; then
            gh_api="$(prompt_value "GitHub API base (blank = github.com; set for GitHub Enterprise)" "")"
        fi
        bb_user="$(prompt_value "Bitbucket bot username" "")"
        if [[ -n "$bb_user" ]]; then
            bb_pass="$(prompt_secret "Bitbucket app password (pullrequest:write)")"
            bb_api="$(prompt_value "Bitbucket API base (blank = api.bitbucket.org; set for Bitbucket Server)" "")"
        fi
        if [[ -n "$gh_token" || -n "$bb_user" ]]; then
            cred_path="$(prompt_value "Write credentials to" "/etc/ddeploy/preview-comment.env")"
            mkdir -p "$(dirname "$cred_path")"
            {
                [[ -n "$gh_token" ]] && printf 'GITHUB_TOKEN="%s"\n' "$gh_token"
                [[ -n "$gh_api" ]] && printf 'GITHUB_API="%s"\n' "$gh_api"
                [[ -n "$bb_user" ]] && printf 'BITBUCKET_USER="%s"\n' "$bb_user"
                [[ -n "$bb_pass" ]] && printf 'BITBUCKET_APP_PASSWORD="%s"\n' "$bb_pass"
                [[ -n "$bb_api" ]] && printf 'BITBUCKET_API="%s"\n' "$bb_api"
            } > "$cred_path"
            chmod 600 "$cred_path"
            log_info "wrote $cred_path (chmod 600)"
            set_conf_value "$target" PREVIEW_COMMENT_CREDENTIALS "$cred_path"
            log_info "set PREVIEW_COMMENT_CREDENTIALS=$cred_path in $target"
        else
            log_info "no token/app-password given — skipping PR comments"
        fi
    fi

    echo
    log_info "wrote $target — run 'sudo ./provision.sh init' to apply"
}

# $1 provider (github|bitbucket)  $2 org/workspace slug  $3 webhook URL
# $4 HMAC secret. Prompts for a token/app-password — used once for this
# API call, never saved anywhere. Registration failure is a warning, not
# fatal: the rest of `configure webhook` (WEBHOOK_ENABLED, the secret
# file, PR comments below) should still land either way.
register_webhook() {
    local provider="$1" org_or_workspace="$2" url="$3" secret="$4"
    local st=0
    case "$provider" in
        github)
            local token; token="$(prompt_secret "  GitHub PAT with admin:org_hook scope (used once, not saved)")"
            DDEPLOY_WEBHOOK_URL="$url" DDEPLOY_WEBHOOK_SECRET="$secret" DDEPLOY_GITHUB_TOKEN="$token" \
                python3 "$PROVISIONER_DIR/lib/register_webhook.py" github "$org_or_workspace" || st=$?
            ;;
        bitbucket)
            local user pass
            user="$(prompt_required "  Bitbucket username (workspace admin)")"
            pass="$(prompt_secret "  Bitbucket app password with Webhooks: Read and write (used once, not saved)")"
            DDEPLOY_WEBHOOK_URL="$url" DDEPLOY_WEBHOOK_SECRET="$secret" DDEPLOY_BITBUCKET_USER="$user" DDEPLOY_BITBUCKET_PASSWORD="$pass" \
                python3 "$PROVISIONER_DIR/lib/register_webhook.py" bitbucket "$org_or_workspace" || st=$?
            ;;
    esac
    if [[ "$st" -eq 0 ]]; then
        log_info "$provider webhook registered"
    else
        log_warn "$provider webhook registration failed (output above) — register it by hand instead (README \"Deploy on git push\")"
    fi
}

# --- shared prompt/file helpers -----------------------------------------

# $1 prompt  $2 default (shown, used if input is blank)
prompt_value() {
    local desc="$1" default="$2" input
    if [[ -n "$default" ]]; then
        read -rp "$desc [$default]: " input
    else
        read -rp "$desc: " input
    fi
    [[ -n "$input" ]] || input="$default"
    [[ "$input" != *'"'* ]] || die "$desc: value cannot contain a double quote"
    printf '%s' "$input"
}

# Same as prompt_value with no default, but dies on empty input.
prompt_required() {
    local desc="$1" val
    val="$(prompt_value "$desc" "")"
    [[ -n "$val" ]] || die "$desc is required"
    printf '%s' "$val"
}

# Same as prompt_required, but doesn't echo the input.
prompt_secret() {
    local desc="$1" input
    read -rsp "$desc: " input
    echo >&2
    [[ -n "$input" ]] || die "$desc is required"
    [[ "$input" != *'"'* ]] || die "$desc: value cannot contain a double quote"
    printf '%s' "$input"
}

# $1 target file  $2 KEY (must already appear as KEY="...") $3 prompt text
# — interactive: shows the current value as the default, prompts, writes.
configure_field() {
    local target="$1" key="$2" desc="$3"
    local current; current="$(get_conf_value "$target" "$key")"
    local input; input="$(prompt_value "$key ($desc)" "$current")"
    set_conf_value "$target" "$key" "$input"
}

# Non-interactive: sets KEY="value" in $1, preserving any trailing
# comment on that line. $2 must already appear in the file as KEY="...".
set_conf_value() {
    local target="$1" key="$2" val="$3"
    [[ "$val" != *'"'* ]] || die "$key: value cannot contain a double quote"
    local tmp; tmp="$(mktemp)"
    awk -v k="$key" -v v="$val" '
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

# Prints KEY's current value from $1 (empty if not found/set).
get_conf_value() {
    local target="$1" key="$2"
    sed -nE "s/^${key}=\"([^\"]*)\".*/\1/p" "$target" | head -1
}
