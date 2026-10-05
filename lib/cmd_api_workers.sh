#!/usr/bin/env bash
# `api workers` / `api schedules`: a site's queue workers and scheduled
# tasks (lib/queue.sh, lib/cmd_schedule.sh) — what's declared, whether it
# runs, how it last went — and the few controls that don't need a deploy:
# restart / stop / start a worker, pause / resume the schedules.
# What runs stays declared in the site's .ddeploy/config.yaml.

# systemd's "Sat 2026-10-04 13:00:00 UTC" as ISO 8601, or empty.
api_systemd_time() {
    [[ -n "$1" && "$1" != "n/a" ]] || return 0
    date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true
}

# Sets AW_QUEUE[] AW_SCHEDULE[] for $1 from its current config.
api_workers_config() {
    local name="$1"
    local cfg_path; cfg_path="$(resolve_config_path "$name")"
    [[ -n "$cfg_path" ]] || api_die conflict "'$name' has no config yet — deploy it first"
    ( parse_config "$name" "$cfg_path" 0 ) >/dev/null 2>&1 || api_die conflict "couldn't read '$name's config"
    parse_config "$name" "$cfg_path" 0 >/dev/null 2>&1
    AW_QUEUE=("${QUEUE_WORKERS[@]}")
    AW_SCHEDULE=("${SCHEDULE[@]}")
}

api_workers_json() {
    local name="$1"
    local preview=false
    is_preview "$name" && preview=true
    local paused=false
    [[ -f "$(schedule_paused_path "$name")" ]] && paused=true
    api_header
    printf ',"site":%s,"preview":%s,"schedules_paused":%s,"workers":[' "$(json_str "$name")" "$preview" "$paused"
    local i first=1 unit props state sub restarts since pid log
    for ((i = 0; i < ${#AW_QUEUE[@]}; i++)); do
        unit="ddeploy-worker-$name-$i"
        state=missing sub="" restarts=null since="" pid=null
        if [[ -f "$WORKER_UNIT_DIR/$unit.service" ]]; then
            props="$(systemctl show "$unit" -p ActiveState -p SubState -p NRestarts -p ActiveEnterTimestamp -p MainPID 2>/dev/null || true)"
            state="$(sed -n 's/^ActiveState=//p' <<< "$props")"
            sub="$(sed -n 's/^SubState=//p' <<< "$props")"
            restarts="$(sed -n 's/^NRestarts=//p' <<< "$props")"
            since="$(api_systemd_time "$(sed -n 's/^ActiveEnterTimestamp=//p' <<< "$props")")"
            pid="$(sed -n 's/^MainPID=//p' <<< "$props")"
        fi
        log="$name.worker-$i"
        [[ "$first" -eq 1 ]] || printf ','
        first=0
        printf '{"index":%s,"command":%s,"unit":%s,"state":%s,"sub_state":%s,"restarts":%s,"since":%s,"pid":%s,"log":%s}' \
            "$i" "$(json_str "${AW_QUEUE[$i]}")" "$(json_str "$unit")" "$(json_str "${state:-unknown}")" "$(json_str "$sub")" \
            "$(json_num "$restarts")" "$( [[ -n "$since" ]] && json_str "$since" || echo null)" \
            "$( [[ "$pid" =~ ^[1-9][0-9]*$ ]] && echo "$pid" || echo null)" \
            "$( [[ -f "$LOG_DIR/$log.log" ]] && json_str "$log" || echo null)"
    done
    printf '],"schedules":['
    local entry cron cmd cronline managed last running
    cronline="$(cat "$SCHEDULE_CRON_DIR/ddeploy-site-$name" 2>/dev/null || true)"
    first=1
    for ((i = 0; i < ${#AW_SCHEDULE[@]}; i++)); do
        entry="${AW_SCHEDULE[$i]}"
        cron="${entry%%$'\t'*}" cmd="${entry#*$'\t'}"
        # Installed the current way (through schedule-run, so it has a
        # history and its own log), the old way (before this ddeploy:
        # until the next deploy), or not at all.
        if grep -q "schedule-run $name $i " <<< "$cronline"; then managed=current
        elif [[ -n "$cronline" ]]; then managed=legacy
        else managed=missing; fi
        last="$(cat "$(schedule_state_path "$name" "$i")" 2>/dev/null || true)"
        [[ "$last" == \{* ]] || last=null
        running=false
        schedule_is_running "$name" "$i" && running=true
        log="$name.schedule-$i"
        [[ "$first" -eq 1 ]] || printf ','
        first=0
        printf '{"index":%s,"cron":%s,"command":%s,"installed":%s,"running":%s,"last":%s,"log":%s}' \
            "$i" "$(json_str "$cron")" "$(json_str "$cmd")" "$(json_str "$managed")" "$running" "$last" \
            "$( [[ -f "$LOG_DIR/$log.log" ]] && json_str "$log" || echo null)"
    done
    printf ']}\n'
}

# api workers <name> [--restart|--stop|--start <index> --actor <email>]
api_workers() {
    local name="${1:-}"
    shift || true
    api_require_site "$name"
    local action="" index="" actor=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --restart|--stop|--start) action="${1#--}"; index="${2:-}"; shift ;;
            --actor) actor="${2:-}"; shift ;;
            *) api_die bad_request "workers: unknown option '$1'" ;;
        esac
        shift
    done
    api_workers_config "$name"
    if [[ -n "$action" ]]; then
        api_valid api_valid_actor "$actor"
        [[ "$index" =~ ^[0-9]{1,2}$ && "$index" -lt "${#AW_QUEUE[@]}" ]] || api_die bad_request "'$name' has no worker #$index"
        local unit="ddeploy-worker-$name-$index"
        [[ -f "$WORKER_UNIT_DIR/$unit.service" ]] || api_die conflict "worker #$index isn't installed yet — deploy '$name'"
        # reset-failed: a worker that crash-looped into systemd's start
        # limit wouldn't start again otherwise.
        systemctl reset-failed "$unit" 2>/dev/null || true
        systemctl "$action" "$unit" || api_die error "systemctl $action $unit failed"
        DDEPLOY_TRIGGER="web ($actor)" event_record "$name" "worker-$action" succeeded "subject=worker #$index: ${AW_QUEUE[$index]:0:80}"
        site_log "$name" "workers: $action #$index (web ($actor))"
        [[ "$action" == stop ]] || sleep 1
    fi
    api_workers_json "$name"
}

# api schedules <name> --pause|--resume --actor <email>
api_schedules() {
    local name="${1:-}"
    shift || true
    api_require_site "$name"
    local action="" actor=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pause|--resume) action="${1#--}" ;;
            --actor) actor="${2:-}"; shift ;;
            *) api_die bad_request "schedules: unknown option '$1'" ;;
        esac
        shift
    done
    [[ -n "$action" ]] || api_die bad_request "schedules: --pause or --resume"
    api_valid api_valid_actor "$actor"
    api_workers_config "$name"
    install -d -m 755 "$SCHEDULE_STATE_DIR"
    if [[ "$action" == pause ]]; then
        printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$actor" > "$(schedule_paused_path "$name")"
    else
        rm -f "$(schedule_paused_path "$name")"
    fi
    DDEPLOY_TRIGGER="web ($actor)" event_record "$name" "schedules-${action}d" succeeded "subject=${#AW_SCHEDULE[@]} scheduled task(s)"
    site_log "$name" "schedules: ${action}d (web ($actor))"
    api_workers_json "$name"
}
