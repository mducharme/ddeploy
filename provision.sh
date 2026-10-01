#!/usr/bin/env bash
# Staging provisioner CLI. See README.md. Every per-server value lives
# in provisioner.conf, never here — this script is identical across servers.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/releases.sh
source "$LIB_DIR/releases.sh"
# shellcheck source=lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=lib/hooks.sh
source "$LIB_DIR/hooks.sh"
# shellcheck source=lib/custom_hooks.sh
source "$LIB_DIR/custom_hooks.sh"
# shellcheck source=lib/cms.sh
source "$LIB_DIR/cms.sh"
# shellcheck source=lib/git_access.sh
source "$LIB_DIR/git_access.sh"
# shellcheck source=lib/cloudflare.sh
source "$LIB_DIR/cloudflare.sh"
# shellcheck source=lib/php.sh
source "$LIB_DIR/php.sh"
# shellcheck source=lib/node.sh
source "$LIB_DIR/node.sh"
# shellcheck source=lib/db.sh
source "$LIB_DIR/db.sh"
# shellcheck source=lib/vhost.sh
source "$LIB_DIR/vhost.sh"
# shellcheck source=lib/queue.sh
source "$LIB_DIR/queue.sh"
# shellcheck source=lib/custom_domain.sh
source "$LIB_DIR/custom_domain.sh"
# shellcheck source=lib/backup.sh
source "$LIB_DIR/backup.sh"
# shellcheck source=lib/db_backup.sh
source "$LIB_DIR/db_backup.sh"
# shellcheck source=lib/persistent.sh
source "$LIB_DIR/persistent.sh"
# shellcheck source=lib/deploy_history.sh
source "$LIB_DIR/deploy_history.sh"
# shellcheck source=lib/preview.sh
source "$LIB_DIR/preview.sh"
# shellcheck source=lib/hook.sh
source "$LIB_DIR/hook.sh"
# shellcheck source=lib/notify.sh
source "$LIB_DIR/notify.sh"
# shellcheck source=lib/preview_comment.sh
source "$LIB_DIR/preview_comment.sh"
# shellcheck source=lib/cli.sh
source "$LIB_DIR/cli.sh"
# shellcheck source=lib/cmd_configure.sh
source "$LIB_DIR/cmd_configure.sh"
# shellcheck source=lib/cmd_init.sh
source "$LIB_DIR/cmd_init.sh"
# shellcheck source=lib/cmd_init_db.sh
source "$LIB_DIR/cmd_init_db.sh"
# shellcheck source=lib/cmd_provision.sh
source "$LIB_DIR/cmd_provision.sh"
# shellcheck source=lib/cmd_override.sh
source "$LIB_DIR/cmd_override.sh"
# shellcheck source=lib/cmd_env.sh
source "$LIB_DIR/cmd_env.sh"
# shellcheck source=lib/cmd_deploy.sh
source "$LIB_DIR/cmd_deploy.sh"
# shellcheck source=lib/cmd_remove.sh
source "$LIB_DIR/cmd_remove.sh"
# shellcheck source=lib/cmd_list.sh
source "$LIB_DIR/cmd_list.sh"
# shellcheck source=lib/cmd_fleet.sh
source "$LIB_DIR/cmd_fleet.sh"
# shellcheck source=lib/cmd_backup.sh
source "$LIB_DIR/cmd_backup.sh"
# shellcheck source=lib/cmd_db_backup.sh
source "$LIB_DIR/cmd_db_backup.sh"
# shellcheck source=lib/cmd_preview.sh
source "$LIB_DIR/cmd_preview.sh"
# shellcheck source=lib/cmd_logs.sh
source "$LIB_DIR/cmd_logs.sh"
# shellcheck source=lib/cmd_restore.sh
source "$LIB_DIR/cmd_restore.sh"
# shellcheck source=lib/cmd_doctor.sh
source "$LIB_DIR/cmd_doctor.sh"
# shellcheck source=lib/cmd_hook.sh
source "$LIB_DIR/cmd_hook.sh"
# shellcheck source=lib/cmd_node_gc.sh
source "$LIB_DIR/cmd_node_gc.sh"

# Runs a deploy-type command ($3...) for site $2 and, if it fails, sends
# a deploy-failure notification carrying the error it printed. The
# command runs in a subshell so its die/exit and EXIT traps behave
# exactly as when called directly; set -e is re-enabled inside it
# explicitly — bash silently disables errexit for anything on the left
# of || / &&, which is why this isn't simply `( "$@" ) || rc=$?`.
# $1 label for the message (deploy, provision-preview, ...).
run_notifying() {
    local label="$1" site="$2"; shift 2
    if [[ -z "$site" ]]; then
        "$@"
        return
    fi
    local errlog; errlog="$(mktemp)"
    local started="$SECONDS" rc
    # Where the site log ends now: on failure, only what this run wrote
    # after this line goes into the notification (notify_failure_output).
    local log_start=0
    if [[ -f "$LOG_DIR/$site.log" ]]; then
        log_start="$(wc -l < "$LOG_DIR/$site.log")"
    fi
    # stderr is copied to $errlog through a pipeline (the pipeline waits
    # for tee, so the file is complete when we read it); stdout goes
    # straight through on fd 3. rc is the command's, not tee's.
    set +e
    { ( set -e; "$@" ) 2>&1 1>&3 3>&- | tee "$errlog" >&2; } 3>&1
    rc="${PIPESTATUS[0]}"
    set -e
    if [[ "$rc" -ne 0 ]]; then
        # `|| true`: no [error] line is a normal case (grep exits 1), and
        # under pipefail + set -e that alone would kill the script here,
        # before the notification is sent.
        local err
        err="$(sed 's/\x1b\[[0-9;]*m//g' "$errlog" | grep -E '^\[error\]' | tail -n 2 | cut -c1-300 || true)"
        [[ -n "$err" ]] || err="$(sed 's/\x1b\[[0-9;]*m//g' "$errlog" | tail -n 3 | cut -c1-300 || true)"
        (
            load_conf
            # The closing line of every failed run in the site's own log,
            # whatever failed (a step, git, config...) — the step-level
            # line and output above it, if any, say more. Skipped when the
            # site doesn't exist at all (a typo'd name), so that doesn't
            # leave an empty log file behind.
            if [[ -d "$(site_root "$site")" || -f "$LOG_DIR/$site.log" ]]; then
                site_log "$site" "$label: FAILED after $((SECONDS - started))s ($(notify_trigger)) — $(head -n1 <<< "$err" | sed 's/^\[error\] *//')"
            fi
            local details="$err" output
            output="$(notify_failure_output "$site" "$log_start")"
            if [[ -n "$output" ]]; then
                details+=$'\n```\n'"$output"$'\n```'
            fi
            details+=$'\n'"Took $((SECONDS - started))s — $(notify_trigger)"$'\n'"Full log: ddeploy logs $site"
            notify_event deploy-failure "$site" "$site: $label FAILED" "$details"
        ) || true
    fi
    rm -f "$errlog"
    return "$rc"
}

# The site a deploy-type invocation is about, for run_notifying — empty
# for help/read-only invocations, which never notify.
notify_site_arg() {
    local kind="$1"; shift
    local a
    for a in "$@"; do
        case "$a" in -h|--help|--history) return 0 ;; esac
    done
    case "$kind" in
        site) [[ -n "${1:-}" && "$1" != -* ]] && printf '%s' "$1" ;;
        preview)
            if [[ -n "${1:-}" && -n "${2:-}" && "$1" != -* && "$2" != -* ]]; then
                # Subshell: preview_slug die()s on a nonsense pair, and
                # that must be the command's own error, reported by it.
                (preview_slug "$1" "$2") 2>/dev/null || true
            fi
            ;;
    esac
    return 0
}

usage() {
    cat <<'EOF'
usage: ddeploy <command> [args]

commands:
  configure                     create/update provisioner.conf (see -h)
  init                          set up a web server (packages, PHP, TLS, firewall)
  init-db                       set up a dedicated database server
  provision <name> [repo-url]   stand up a site (see: ddeploy provision -h)
  override <name> [opts]        operator-side config override, no repo access needed (see -h)
  env <name> [KEY=value] [opts] show/edit a site's persistent .env (see -h)
  deploy <name> [opts]          new release + re-apply vhost/FPM config + replay hooks (see -h)
  remove <name> [opts]          disable a site (see: ddeploy remove -h)
  list                          table of provisioned sites
  provision-all                 provision every site in /etc/ddeploy/manifest
  deploy-all                    deploy every provisioned site
  backup-uploads [name]         sync upload_dirs to object storage (needs BACKUP_ENABLED=true)
  backup-database [name]        dump + upload each site's DB (needs DB_BACKUP_ENABLED=true)
  restore-uploads <name> --yes  overwrite local upload_dirs from the backup (see -h)
  restore-database <name> [--from <file> | --from-file <path>] --yes   overwrite the DB from a dump (see -h)
  provision-preview <project> <branch> [repo-url] [opts]   branch preview (see -h)
  deploy-preview <project> <branch>       pull + redeploy a preview
  remove-preview <project> <branch> [opts]   remove a preview (see -h)
  prune-previews [project]      remove previews whose branch no longer exists
  preview-url <project> <branch>   print https://<slug>.$BASE_DOMAIN (see -h)
  logs <name> [-n N] [-f]       tail a site or fleet log, or the webhook log: logs webhook (see -h)
  notify <name> [opts]          per-site Slack/Discord webhook for deploy notifications (see -h)
  doctor [name]                 health check: nginx/PHP-FPM/DB/disk/certs (see -h)
  node-gc [--yes]               remove Node versions nothing uses any more (see -h)
  install-cli                   (re)install the ddeploy command + bash completion (init does this too)
  hook-worker                   drain the git-push webhook queue (systemd; not an operator command)
EOF
}

main() {
    local cmd="${1:-}"
    if [[ $# -gt 0 ]]; then
        shift
    fi
    case "$cmd" in
        configure)      cmd_configure "$@" ;;
        init)           cmd_init "$@" ;;
        init-db)        cmd_init_db "$@" ;;
        provision)      run_notifying provision "$(notify_site_arg site "$@")" cmd_provision "$@" ;;
        override)       cmd_override "$@" ;;
        env)            cmd_env "$@" ;;
        deploy)         run_notifying deploy "$(notify_site_arg site "$@")" cmd_deploy "$@" ;;
        remove)         cmd_remove "$@" ;;
        list)           cmd_list "$@" ;;
        provision-all)  cmd_provision_all "$@" ;;
        deploy-all)     cmd_deploy_all "$@" ;;
        backup-uploads) cmd_backup_uploads "$@" ;;
        backup-database) cmd_backup_database "$@" ;;
        restore-uploads) cmd_restore_uploads "$@" ;;
        restore-database) cmd_restore_database "$@" ;;
        provision-preview) run_notifying provision-preview "$(notify_site_arg preview "$@")" cmd_provision_preview "$@" ;;
        deploy-preview) run_notifying deploy-preview "$(notify_site_arg preview "$@")" cmd_deploy_preview "$@" ;;
        remove-preview) cmd_remove_preview "$@" ;;
        prune-previews) cmd_prune_previews "$@" ;;
        preview-url)    cmd_preview_url "$@" ;;
        logs)           cmd_logs "$@" ;;
        notify)         cmd_notify "$@" ;;
        doctor)         cmd_doctor "$@" ;;
        node-gc)        cmd_node_gc "$@" ;;
        install-cli)    cmd_install_cli "$@" ;;
        hook-worker)    cmd_hook_worker "$@" ;;
        -h|--help|help|"") usage ;;
        *) usage; die "unknown command: $cmd" ;;
    esac
}

main "$@"
