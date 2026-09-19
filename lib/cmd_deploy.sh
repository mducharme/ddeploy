#!/usr/bin/env bash
# `deploy <name>` — pull, replay post-start hooks, reload. This is the
# CI target: the pipeline's SSH command becomes `provision.sh deploy <name>`.
# `deploy <name> --rollback [<sha>]` moves the code backward instead — see
# lib/deploy_history.sh and usage_deploy below for what that does and
# doesn't cover.

usage_deploy() {
    cat <<'EOF'
usage: provision.sh deploy <name> [--rollback [<sha>]]
       provision.sh deploy <name> --history

options:
  --rollback [<sha>]   instead of pulling, `git reset --hard` to <sha> (or,
                        if omitted, the most recent different commit this
                        tool has itself deployed) and replay hooks — see
                        README "Rolling back" for what this does and does
                        NOT undo (database migrations are not reversed)
  --history             print this site's deploy history (newest last) and
                        exit — use a SHA from here with --rollback
EOF
}

cmd_deploy() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_deploy; return 0; }
    load_conf
    require_root

    local name="${1:-}"
    [[ -n "$name" ]] || { usage_deploy; die "site name required"; }
    shift || true
    validate_name "$name"

    local rollback=0 rollback_sha="" history=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rollback)
                rollback=1
                if [[ -n "${2:-}" && "$2" != --* ]]; then rollback_sha="$2"; shift; fi
                ;;
            --history) history=1 ;;
            -h|--help) usage_deploy; return 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done

    local dir; dir="$(site_dir "$name")"
    [[ -d "$dir/.git" ]] || die "$dir is not a git repo — provision it first"

    if [[ "$history" -eq 1 ]]; then
        local f; f="$(deploy_history_path "$name")"
        if [[ -s "$f" ]]; then
            log_info "deploy history for '$name' (newest last):"
            while IFS=$'\t' read -r ts sha; do
                printf '  %s  %s\n' "$ts" "$(git -C "$dir" log -1 --format='%h %s' "$sha" 2>/dev/null || echo "$sha")"
            done < "$f"
        else
            log_info "no deploy history recorded for '$name' yet"
        fi
        return 0
    fi

    local cfg_path; cfg_path="$(resolve_config_path "$name")"
    [[ -n "$cfg_path" ]] || die "no config for '$name' (no .ddev/config.yaml or generated sidecar) — run provision first"

    # Re-synced on every deploy (cheap, idempotent) so a rotated
    # GIT_DEPLOY_KEY propagates without a separate command.
    sync_site_ssh "$name" "$dir"

    local current_sha; current_sha="$(git -C "$dir" log -1 --format=%H)"

    if [[ "$rollback" -eq 1 ]]; then
        local target="$rollback_sha"
        if [[ -z "$target" ]]; then
            target="$(previous_deploy_sha "$name" "$current_sha")" \
                || die "no earlier deploy recorded for '$name' to roll back to — pass an explicit <sha> (see --history), or there simply isn't one yet"
        fi
        git -C "$dir" cat-file -e "${target}^{commit}" 2>/dev/null \
            || die "'$target' isn't a commit '$name's checkout knows about"
        log_warn "rolling back '$name': $(git -C "$dir" log -1 --format=%h "$current_sha") -> $(git -C "$dir" log -1 --format=%h "$target") — this moves the CODE back only; any database migration already applied by a later deploy is NOT undone"
        sudo -u "www-$name" env HOME="$dir" git -C "$dir" reset --hard "$target" 2>&1 | tee -a "$LOG_DIR/$name.log"
    else
        log_info "git pull --ff-only ($name)"
        sudo -u "www-$name" env HOME="$dir" git -C "$dir" pull --ff-only 2>&1 | tee -a "$LOG_DIR/$name.log"
    fi

    parse_config "$name" "$cfg_path" 1
    # Idempotent and cheap — re-links anything new in upload_dirs/
    # persistent_files since the last deploy, same reasoning as
    # sync_site_ssh re-running on every deploy rather than only at
    # provision time.
    link_persistent_files "$name" "$dir"
    scan_hooks "$name"
    replay_hooks "$name" "$PHP_VERSION" "$dir"
    run_repo_hook "$name" "$PHP_VERSION" "$dir" ".provisioner/post-deploy.sh" "post-deploy script"
    run_ops_hooks "post-deploy" "$name" "$dir" "$PHP_VERSION"

    systemctl reload "php${PHP_VERSION}-fpm" 2>/dev/null || true
    nginx -t && systemctl reload nginx

    local full_sha; full_sha="$(git -C "$dir" log -1 --format=%H)"
    local sha; sha="$(git -C "$dir" log -1 --format=%h)"
    record_deploy "$name" "$full_sha"
    if [[ "$rollback" -eq 1 ]]; then
        site_log "$name" "rollback: done at $sha"
        log_info "rolled back $name @ $sha"
    else
        site_log "$name" "deploy: done at $sha"
        log_info "deployed $name @ $sha"
    fi
}
