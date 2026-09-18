#!/usr/bin/env bash
# `deploy <name>` — pull, replay post-start hooks, reload. This is the
# CI target: the pipeline's SSH command becomes `provision.sh deploy <name>`.

cmd_deploy() {
    load_conf
    require_root

    local name="${1:-}"
    [[ -n "$name" ]] || die "usage: provision.sh deploy <name>"
    validate_name "$name"

    local dir; dir="$(site_dir "$name")"
    [[ -d "$dir/.git" ]] || die "$dir is not a git repo — provision it first"

    local cfg_path; cfg_path="$(resolve_config_path "$name")"
    [[ -n "$cfg_path" ]] || die "no config for '$name' (no .ddev/config.yaml or generated sidecar) — run provision first"

    # Re-synced on every deploy (cheap, idempotent) so a rotated
    # GIT_DEPLOY_KEY propagates without a separate command.
    sync_site_ssh "$name" "$dir"

    log_info "git pull --ff-only ($name)"
    sudo -u "www-$name" env HOME="$dir" git -C "$dir" pull --ff-only 2>&1 | tee -a "$LOG_DIR/$name.log"

    parse_config "$name" "$cfg_path" 1
    scan_hooks "$name"
    replay_hooks "$name" "$PHP_VERSION" "$dir"
    run_repo_hook "$name" "$PHP_VERSION" "$dir" ".provisioner/post-deploy.sh" "post-deploy script"
    run_ops_hooks "post-deploy" "$name" "$dir" "$PHP_VERSION"

    systemctl reload "php${PHP_VERSION}-fpm" 2>/dev/null || true
    nginx -t && systemctl reload nginx

    local sha; sha="$(git -C "$dir" log -1 --format=%h)"
    site_log "$name" "deploy: done at $sha"
    log_info "deployed $name @ $sha"
}
