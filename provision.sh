#!/usr/bin/env bash
# Staging provisioner CLI. See README.md. Every per-server value lives
# in provisioner.conf, never here — this script is identical across servers.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/json.sh
source "$LIB_DIR/json.sh"
# shellcheck source=lib/events.sh
source "$LIB_DIR/events.sh"
# shellcheck source=lib/index.sh
source "$LIB_DIR/index.sh"
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
# shellcheck source=lib/cmd_init_web.sh
source "$LIB_DIR/cmd_init_web.sh"
# shellcheck source=lib/cmd_db.sh
source "$LIB_DIR/cmd_db.sh"
# shellcheck source=lib/cmd_uploads.sh
source "$LIB_DIR/cmd_uploads.sh"
# shellcheck source=lib/cmd_fetch.sh
source "$LIB_DIR/cmd_fetch.sh"
# shellcheck source=lib/cmd_api.sh
source "$LIB_DIR/cmd_api.sh"
# shellcheck source=lib/cmd_api_config.sh
source "$LIB_DIR/cmd_api_config.sh"
# shellcheck source=lib/cmd_api_fetch.sh
source "$LIB_DIR/cmd_api_fetch.sh"
# shellcheck source=lib/cmd_api_files.sh
source "$LIB_DIR/cmd_api_files.sh"
# shellcheck source=lib/cmd_schedule.sh
source "$LIB_DIR/cmd_schedule.sh"
# shellcheck source=lib/steps.sh
source "$LIB_DIR/steps.sh"
# shellcheck source=lib/cmd_api_debug.sh
source "$LIB_DIR/cmd_api_debug.sh"
# shellcheck source=lib/cmd_api_workers.sh
source "$LIB_DIR/cmd_api_workers.sh"

# Runs a deploy-type command ($3...) for site $2 and, if it fails, sends
# a deploy-failure notification carrying the error it printed. The
# command runs in a subshell so its die/exit and EXIT traps behave
# exactly as when called directly; set -e is re-enabled inside it
# explicitly — bash silently disables errexit for anything on the left
# of || / &&, which is why this isn't simply `( "$@" ) || rc=$?`.
# $1 label for the message (deploy, provision-preview, ...).
run_notifying() {
    local label="$1" site="$2"; shift 2
    # Not a plain site name: the command itself will refuse it — and the
    # name is about to become a log path and part of a trap string.
    if [[ -z "$site" || ! "$site" =~ $NAME_RE ]]; then
        "$@"
        return
    fi
    local errlog; errlog="$(mktemp)"
    local started="$SECONDS" rc
    # A run detached from any terminal (the web UI's, a webhook's, cron's)
    # is read back from its run log: timestamp its lines like every
    # other log. Someone at a terminal sees them plain.
    log_timestamps_unless_tty

    # Every run gets an id (kept if `api run start` already assigned
    # one), a full output log, and start/end events — see lib/events.sh.
    if [[ ! "${DDEPLOY_RUN_ID:-}" =~ $RUN_ID_RE ]]; then
        DDEPLOY_RUN_ID="$(new_run_id)"
    fi
    export DDEPLOY_RUN_ID
    DDEPLOY_EVENT_ATTRS="$(mktemp)"
    export DDEPLOY_EVENT_ATTRS
    local runlog=/dev/null
    if [[ "$EUID" -eq 0 ]] && mkdir -p "$RUNS_LOG_DIR" 2>/dev/null; then
        chmod 750 "$RUNS_LOG_DIR" 2>/dev/null || true
        prune_run_logs
        prune_run_steps
        # A detached `api run start` already points the unit's own
        # stdout/stderr at this file (so lines from before this point,
        # like waiting on the site lock, land in it too) — teeing here as
        # well would write every line twice.
        [[ "${DDEPLOY_RUN_LOG_EXTERNAL:-}" == 1 ]] || runlog="$RUNS_LOG_DIR/$DDEPLOY_RUN_ID.log"
    fi
    local -a start_attrs=()
    case "$label" in
        provision-preview|deploy-preview|remove-preview) start_attrs=("project=${2:-}" "branch=${3:-}") ;;
    esac
    [[ "$EUID" -eq 0 ]] && event_record "$site" "$label" started "${start_attrs[@]}"
    # Where the site log ends now: on failure, only what this run wrote
    # after this line goes into the notification (notify_failure_output).
    local log_start=0
    if [[ -f "$LOG_DIR/$site.log" ]]; then
        log_start="$(wc -l < "$LOG_DIR/$site.log")"
    fi
    # stderr is copied to $errlog through a pipeline (the pipeline waits
    # for tee, so the file is complete when we read it); stdout goes
    # straight through on fd 3. rc is the command's, not tee's.
    # Stopped from outside (`api run cancel`, systemctl stop, a reboot's
    # SIGTERM): still record how the run ended, so it doesn't read as
    # running forever. The pipeline's own processes get the same signal,
    # so bash runs this as soon as they've exited. A release that wasn't
    # switched in yet is discarded by cmd_deploy's own EXIT trap.
    # shellcheck disable=SC2064  # expand $site/$label/$started now
    trap "[[ \$EUID -eq 0 ]] && event_record '$site' \"\$(event_attr_get \"\$DDEPLOY_EVENT_ATTRS\" kind '$label')\" failed \"duration_s=\$((SECONDS - $started))\" 'error=interrupted (stopped before it finished)'; rm -f \"\$DDEPLOY_EVENT_ATTRS\" '$errlog'; exit 143" TERM INT HUP
    set +e
    { ( set -e; "$@" ) 2>&1 1>&3 3>&- | tee -a "$errlog" "$runlog" >&2; } 3>&1
    rc="${PIPESTATUS[0]}"
    set -e
    trap - TERM INT HUP
    # Which step a failure hit, and whether the new code had gone live.
    local failed_step=""
    [[ "$rc" -eq 0 ]] || failed_step="$(step_open_label)"
    step_end "$( [[ "$rc" -eq 0 ]] && echo ok || echo failed )"
    local -a end_attrs=("${start_attrs[@]}") key
    for key in from_sha to_sha subject author branch project; do
        end_attrs+=("$key=$(event_attr_get "$DDEPLOY_EVENT_ATTRS" "$key")")
    done
    end_attrs+=("duration_s=$((SECONDS - started))")
    local end_kind end_phase
    end_kind="$(event_attr_get "$DDEPLOY_EVENT_ATTRS" kind "$label")"
    if [[ "$rc" -eq 0 ]]; then
        end_phase="$(event_attr_get "$DDEPLOY_EVENT_ATTRS" phase succeeded)"
    else
        end_phase=failed
        [[ -n "$failed_step" ]] && end_attrs+=("failed_step=$failed_step")
        case "$label" in
            deploy|deploy-preview) if steps_went_live; then end_attrs+=("live=yes"); else end_attrs+=("live=no"); fi ;;
        esac
        # [error] at the start of a line, or after log_timestamps' prefix (cron, backups).
        end_attrs+=("error=$(sed 's/\x1b\[[0-9;]*m//g' "$errlog" | grep -E '^([0-9T:-]+Z )?\[error\]' | tail -n 1 | sed -E 's/^([0-9T:-]+Z )?\[error\] *//' | cut -c1-300 || true)")
    fi
    [[ "$EUID" -eq 0 ]] && event_record "$site" "$end_kind" "$end_phase" "${end_attrs[@]}"
    rm -f "$DDEPLOY_EVENT_ATTRS"
    if [[ "$rc" -ne 0 ]]; then
        # `|| true`: no [error] line is a normal case (grep exits 1), and
        # under pipefail + set -e that alone would kill the script here,
        # before the notification is sent.
        local err
        err="$(sed 's/\x1b\[[0-9;]*m//g' "$errlog" | grep -E '^([0-9T:-]+Z )?\[error\]' | tail -n 2 | cut -c1-300 || true)"
        [[ -n "$err" ]] || err="$(sed 's/\x1b\[[0-9;]*m//g' "$errlog" | tail -n 3 | cut -c1-300 || true)"
        (
            load_conf
            # The closing line of every failed run in the site's own log,
            # whatever failed (a step, git, config...) — the step-level
            # line and output above it, if any, say more. Skipped when the
            # site doesn't exist at all (a typo'd name), so that doesn't
            # leave an empty log file behind.
            if [[ -d "$(site_root "$site")" || -f "$LOG_DIR/$site.log" ]]; then
                site_log "$site" "$label: FAILED after $((SECONDS - started))s ($(notify_trigger)) — $(head -n1 <<< "$err" | sed 's/^\[error\] *//')" error
            fi
            local details="$err" output
            output="$(notify_failure_output "$site" "$log_start")"
            if [[ -n "$output" ]]; then
                details+=$'\n```\n'"$output"$'\n```'
            fi
            [[ -n "$failed_step" ]] && details="Failed at: $failed_step"$'\n'"$details"
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
  db-import <name> --from-file <path> --yes   snapshot the DB, then load a dump into it (see -h)
  db-snapshot <name> [--list]   local safety dump of a site's DB (see -h)
  uploads-import <name> --dir <d> --from-file <archive> --yes   unpack files into an upload dir, snapshot first (see -h)
  uploads-snapshot <name> [--list]   hardlink snapshot of a site's upload dirs (see -h)
  fetch-key [--forget <host>]   key for copying upload dirs from another server over SSH (see -h)
  provision-preview <project> <branch> [repo-url] [opts]   branch preview (see -h)
  deploy-preview <project> <branch>       pull + redeploy a preview
  remove-preview <project> <branch> [opts]   remove a preview (see -h)
  prune-previews [project]      remove previews whose branch no longer exists
  preview-url <project> <branch>   print https://<slug>.$BASE_DOMAIN (see -h)
  logs <name> [-n N] [-f]       tail a site or fleet log, or the webhook log: logs webhook (see -h)
  notify <name> [opts]          per-site Slack/Discord webhook for deploy notifications (see -h)
  doctor [-v] [name]            health check: nginx/PHP-FPM/DB/disk/certs (see -h)
  node-gc [--yes]               remove Node versions nothing uses any more (see -h)
  init-web                      set up the web UI's user, sudoers rule and vhost (see -h)
  api <verb> [args]             JSON interface for the web UI (see: ddeploy api -h)
  install-cli                   (re)install the ddeploy command + bash completion (init does this too)
  hook-worker                   drain the git-push webhook queue (systemd; not an operator command)
EOF
}

# Serializes every run against one site — CLI, webhook and web alike —
# by re-executing this whole command under `flock -o` on the site's lock
# file (the same one hook-worker's with_site_lock takes, which sets
# DDEPLOY_LOCK_HELD so this doesn't then wait on itself). -o closes the
# lock fd in the child: anything a deploy leaves running (an ssh-agent, a
# restarted worker) can't inherit the lock and hold it forever. $1 site
# (empty, or not a valid name: no lock — the command reports that
# itself), rest the full original argv.
site_lock_reexec() {
    local site="$1"; shift
    [[ -n "$site" && "$site" =~ $NAME_RE && "$EUID" -eq 0 ]] || return 0
    [[ "${DDEPLOY_LOCK_HELD:-}" == "$site" ]] && return 0
    command -v flock >/dev/null 2>&1 || return 0
    local lock_dir="$DDEPLOY_STATE/locks"
    mkdir -p "$lock_dir"
    if ! flock -n "$lock_dir/$site.lock" true; then
        log_info "'$site': another run holds this site's lock — waiting for it to finish"
    fi
    DDEPLOY_LOCK_HELD="$site" exec flock -o "$lock_dir/$site.lock" "$PROVISIONER_DIR/provision.sh" "$@"
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        provision|deploy|remove|restore-database|db-import|uploads-import) site_lock_reexec "$(notify_site_arg site "${@:2}")" "$@" ;;
        provision-preview|deploy-preview|remove-preview) site_lock_reexec "$(notify_site_arg preview "${@:2}")" "$@" ;;
    esac
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
        # One site: a run of its own (events, output log); none: the
        # fleet-wide cron job, which records an event per site itself.
        backup-uploads)
            if [[ -n "${1:-}" && "$1" != -* ]]; then run_notifying backup-uploads "$1" cmd_backup_uploads "$@"
            else cmd_backup_uploads "$@"
            fi ;;
        backup-database)
            if [[ -n "${1:-}" && "$1" != -* ]]; then run_notifying backup-database "$1" cmd_backup_database "$@"
            else cmd_backup_database "$@"
            fi ;;
        restore-uploads) cmd_restore_uploads "$@" ;;
        restore-database) cmd_restore_database "$@" ;;
        db-import)      run_notifying db-import "$(notify_site_arg site "$@")" cmd_db_import "$@" ;;
        uploads-import) run_notifying uploads-import "$(notify_site_arg site "$@")" cmd_uploads_import "$@" ;;
        fetch-key)      cmd_fetch_key "$@" ;;
        # From cron: plain (no history event per minute). From the web UI
        # ("Run now", a detached run): wrapped, so it's a run with a log.
        schedule-run)
            if [[ -n "${DDEPLOY_RUN_ID:-}" ]]; then run_notifying schedule-run "$(notify_site_arg site "$@")" cmd_schedule_run "$@"
            else cmd_schedule_run "$@"
            fi ;;
        uploads-snapshot)
            if [[ " $* " == *" --list "* ]]; then cmd_uploads_snapshot "$@"
            else run_notifying uploads-snapshot "$(notify_site_arg site "$@")" cmd_uploads_snapshot "$@"
            fi ;;
        db-snapshot)
            if [[ " $* " == *" --list "* ]]; then cmd_db_snapshot "$@"
            else run_notifying db-snapshot "$(notify_site_arg site "$@")" cmd_db_snapshot "$@"
            fi ;;
        provision-preview) run_notifying provision-preview "$(notify_site_arg preview "$@")" cmd_provision_preview "$@" ;;
        deploy-preview) run_notifying deploy-preview "$(notify_site_arg preview "$@")" cmd_deploy_preview "$@" ;;
        remove-preview) run_notifying remove-preview "$(notify_site_arg preview "$@")" cmd_remove_preview "$@" ;;
        prune-previews) cmd_prune_previews "$@" ;;
        preview-url)    cmd_preview_url "$@" ;;
        logs)           cmd_logs "$@" ;;
        notify)         cmd_notify "$@" ;;
        doctor)         cmd_doctor "$@" ;;
        node-gc)        cmd_node_gc "$@" ;;
        init-web)       cmd_init_web "$@" ;;
        api)            cmd_api "$@" ;;
        install-cli)    cmd_install_cli "$@" ;;
        hook-worker)    cmd_hook_worker "$@" ;;
        -h|--help|help|"") usage ;;
        *) usage; die "unknown command: $cmd" ;;
    esac
}

main "$@"
