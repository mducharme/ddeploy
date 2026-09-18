#!/usr/bin/env bash
# Two extension points beyond .ddev/config.yaml's hooks:
#
#   - a per-site script committed IN THE CLIENT REPO, run as www-<name>
#     (same trust level as any other exec/composer hook step) — for
#     site-specific one-offs like symlinking a shared uploads path.
#   - fleet-wide ops scripts living on the server under hooks/*.d/, run
#     as root for every site — for operator concerns like registering a
#     site with monitoring or notifying Slack on deploy.
#
# Both are optional; a missing directory/file is silently a no-op.

# $1 name, $2 php, $3 site dir, $4 script path relative to the site dir,
# $5 label for logging, $6/$7 (optional) exec user/home — see
# replay_hooks in lib/hooks.sh for why a shared-mode preview overrides these.
run_repo_hook() {
    local name="$1" php="$2" dir="$3" script_rel="$4" label="$5" exec_user="${6:-www-$name}" exec_home="${7:-$dir}"
    local script="$dir/$script_rel"
    [[ -f "$script" ]] || return 0
    if [[ ! -x "$script" ]]; then
        log_warn "$label found at $script_rel but is not executable — skipping (chmod +x it in the repo)"
        return 0
    fi

    local shim; shim="$(ensure_php_shim "$php")"
    log_info "running $label: $script_rel"
    site_log "$name" "$label: $script_rel"
    sudo -u "$exec_user" env HOME="$exec_home" PATH="$shim:/usr/bin:/bin" bash -lc "cd '$dir' && ./$script_rel"
}

# $1 stage ("post-provision" or "post-deploy"), $2 name, $3 site dir, $4 php.
# Runs every executable *.sh under hooks/<stage>.d/, in sorted order, as
# root, with NAME/SITE_DIR/PHP_VERSION/BASE_DOMAIN in the environment.
run_ops_hooks() {
    local stage="$1" name="$2" dir="$3" php="$4"
    local hooks_dir="$PROVISIONER_DIR/hooks/${stage}.d"
    [[ -d "$hooks_dir" ]] || return 0

    local f
    for f in "$hooks_dir"/*.sh; do
        [[ -e "$f" ]] || continue
        if [[ ! -x "$f" ]]; then
            log_warn "ops hook $f is not executable — skipping (chmod +x it)"
            continue
        fi
        log_info "running ops hook: $(basename "$f")"
        site_log "$name" "ops hook ($stage): $(basename "$f")"
        NAME="$name" SITE_DIR="$dir" PHP_VERSION="$php" BASE_DOMAIN="$BASE_DOMAIN" "$f"
    done
}
