#!/usr/bin/env bash
# Per-site queue workers (persistent, supervised systemd services — a
# Craft `queue/listen`, a Laravel `queue:work`) and scheduled commands
# (cron-style — a Craft `queue/run`/`gc` on a timer, a Laravel
# `schedule:run` every minute). Declared in .ddeploy/config.yaml's
# queue_workers:/schedule: — see README "Queue workers & scheduled
# tasks". Both run as the site's own www-<name> user under its pinned
# PHP version, same isolation as everything else this tool runs —
# never root, never the shared FPM pool user.
#
# A command is spliced into a generated wrapper script exactly the way
# replay_hooks (lib/hooks.sh) already splices a hooks.post-start exec
# step — same trust model (this is the project's own declared deploy
# config, not untrusted input), same PATH/PHP-shim setup. The wrapper
# script exists so the raw command never has to survive systemd's
# unit-file quoting/specifier-expansion rules (a literal % in a command
# is a systemd specifier unless escaped %%) or be embedded in a cron
# line at all — ExecStart=/the cron line just name a plain script path.

WORKER_UNIT_DIR="/etc/systemd/system"
SCHEDULE_CRON_DIR="/etc/cron.d"

# $1 script path  $2 site dir (cd target)  $3 raw command  $4 PHP shim
# dir  $5 HOME. Root-owned; systemd's User=/cron's own user field — not
# this script — is what actually drops privileges to www-<name>.
write_worker_script() {
    local path="$1" dir="$2" cmd="$3" shim="$4" home="$5"
    cat > "$path" <<EOF
#!/bin/bash
set -e
cd '$dir'
export HOME='$home'
export PATH='$shim:/usr/bin:/bin'
$cmd
EOF
    chmod 755 "$path"
    chown root:root "$path"
}

# $1 name  $2 php version  $3 site dir (current, stable across deploys —
# never the ephemeral release path a future deploy will prune)  $4 exec
# user  $5 exec group  $6 HOME  remaining args: QUEUE_WORKERS[] entries.
install_queue_workers() {
    local name="$1" php="$2" dir="$3" exec_user="$4" exec_group="$5" home="$6"
    shift 6
    local -a workers=("$@")
    local shim; shim="$(ensure_php_shim "$php")"

    local i script unit
    for ((i = 0; i < ${#workers[@]}; i++)); do
        script="$GENERATED_DIR/$name.worker-$i.sh"
        unit="$WORKER_UNIT_DIR/ddeploy-worker-$name-$i.service"
        write_worker_script "$script" "$dir" "${workers[$i]}" "$shim" "$home"
        render_template "$PROVISIONER_DIR/templates/queue-worker.service.tmpl" "$unit" \
            "NAME=$name" "INDEX=$i" "POOL_USER=$exec_user" "POOL_GROUP=$exec_group" "WRAPPER=$script"
    done
    # A redeploy that now declares fewer workers than before must not
    # leave the extra ones running forever.
    remove_stale_queue_workers "$name" "${#workers[@]}"

    if [[ "${#workers[@]}" -gt 0 ]]; then
        systemctl daemon-reload
        # Restarted unconditionally, not just enabled — a persistent
        # worker keeps running the code it started with until something
        # restarts it; without this it would silently keep serving the
        # PREVIOUS release's code forever after a deploy (the same
        # reason Laravel ships `queue:restart` as its own command).
        for ((i = 0; i < ${#workers[@]}; i++)); do
            systemctl enable "ddeploy-worker-$name-$i"
            systemctl restart "ddeploy-worker-$name-$i"
        done
        log_info "installed ${#workers[@]} queue worker(s) for $name"
    fi
}

# Removes worker units/scripts at index >= $2 — $1 name, $2 how many to
# KEEP (indices 0..$2-1 survive).
remove_stale_queue_workers() {
    local name="$1" keep="$2"
    local unit i reload=0
    for unit in "$WORKER_UNIT_DIR"/ddeploy-worker-"$name"-*.service; do
        [[ -f "$unit" ]] || continue
        i="$(basename "$unit" .service)"
        i="${i##*-}"
        [[ "$i" =~ ^[0-9]+$ ]] || continue
        [[ "$i" -lt "$keep" ]] && continue
        systemctl disable --now "$(basename "$unit")" >/dev/null 2>&1 || true
        rm -f "$unit" "$GENERATED_DIR/$name.worker-$i.sh"
        reload=1
        log_info "removed stale queue worker $name#$i"
    done
    # Not `[[ ... ]] && systemctl ...` — when reload stays 0 (the common
    # case: nothing stale to remove), that would make this whole function
    # return the false condition's exit status (1), and every caller here
    # invokes it as a bare statement — under set -e that silently kills
    # the entire script, with no error output at all.
    if [[ "$reload" -eq 1 ]]; then
        systemctl daemon-reload
    fi
}

# Stops/disables/removes every queue worker unit for $1 — called
# unconditionally from `remove` (this is code-associated infra, like the
# FPM pool/vhost, not data — no --purge flag gates it).
remove_all_queue_workers() {
    remove_stale_queue_workers "$1" 0
}

# $1 name  $2 php version  $3 site dir  $4 exec user  $5 HOME  remaining
# args: SCHEDULE[] entries as cron<TAB>cmd (parse_config's shape).
install_schedule() {
    local name="$1" php="$2" dir="$3" exec_user="$4" home="$5"
    shift 5
    local -a entries=("$@")

    if [[ "${#entries[@]}" -eq 0 ]]; then
        remove_schedule "$name"
        return 0
    fi

    local shim; shim="$(ensure_php_shim "$php")"
    local tmp; tmp="$(mktemp)"
    local i entry cron cmd script
    for ((i = 0; i < ${#entries[@]}; i++)); do
        entry="${entries[$i]}"
        cron="${entry%%$'\t'*}"
        cmd="${entry#*$'\t'}"
        script="$GENERATED_DIR/$name.schedule-$i.sh"
        write_worker_script "$script" "$dir" "$cmd" "$shim" "$home"
        # NOT `<user>` as the cron.d field directly — www-<name> is
        # created with --shell /usr/sbin/nologin (lib/vhost.sh), and cron
        # silently refuses to exec anything for a user whose shell isn't
        # a real one: it opens and closes the PAM session but never
        # actually runs the command (confirmed empirically in a real
        # systemd container — no CMD line in the journal at all, no
        # error, nothing). `root` + `runuser -u` sidesteps cron's own
        # shell lookup entirely; runuser setuid()s directly rather than
        # exec'ing the target user's shell as -c.
        printf '%s root runuser -u %s -- %s >> %s/%s.log 2>&1\n' "$cron" "$exec_user" "$script" "$LOG_DIR" "$name" >> "$tmp"
    done
    # A redeploy with fewer schedule entries than before must not leave
    # a stale wrapper script (harmless on its own, since nothing
    # references it once its cron line is gone, but still dead weight).
    local old oi
    for old in "$GENERATED_DIR/$name".schedule-*.sh; do
        [[ -f "$old" ]] || continue
        oi="${old##*schedule-}"; oi="${oi%.sh}"
        [[ "$oi" =~ ^[0-9]+$ && "$oi" -lt "${#entries[@]}" ]] && continue
        rm -f "$old"
    done
    chmod 644 "$tmp"
    mv "$tmp" "$SCHEDULE_CRON_DIR/ddeploy-site-$name"
    log_info "installed ${#entries[@]} scheduled task(s) for $name via $SCHEDULE_CRON_DIR/ddeploy-site-$name (runs as $exec_user)"
}

# Removes $1's cron.d file and every schedule wrapper script — called
# unconditionally from `remove`, same as remove_all_queue_workers.
remove_schedule() {
    local name="$1"
    rm -f "$SCHEDULE_CRON_DIR/ddeploy-site-$name"
    rm -f "$GENERATED_DIR/$name".schedule-*.sh
}
