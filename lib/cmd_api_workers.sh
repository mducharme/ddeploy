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

# A config file's queue_workers / schedule as JSON ([] when absent).
aw_workers_list() {
    [[ -n "$1" && -f "$1" ]] || { printf '[]'; return; }
    yq -o=json -I=0 '[(.queue_workers // [])[] | select(. != null) | tostring]' "$1" 2>/dev/null || printf '[]'
}
aw_schedule_list() {
    [[ -n "$1" && -f "$1" ]] || { printf '[]'; return; }
    yq -o=json -I=0 '[(.schedule // [])[] | {"cron": (.cron // "" | tostring), "cmd": (.cmd // "" | tostring)}]' "$1" 2>/dev/null || printf '[]'
}
# $1 server list $2 repo list: which one the site runs.
aw_source() {
    if [[ "$1" != "[]" ]]; then echo server
    elif [[ "$2" != "[]" ]]; then echo repo
    else echo none; fi
}

# What the site is built on, for the UI's ready-made commands: the CMS
# detection provisioning uses, plus Laravel and Symfony (not CMSes, so
# detect_cms leaves them out).
aw_framework() {
    local dir; dir="$(site_dir "$1")"
    local cms; cms="$(detect_cms "$dir" 2>/dev/null || true)"
    if [[ -n "$cms" ]]; then echo "$cms"
    elif [[ -f "$dir/artisan" ]]; then echo laravel
    elif [[ -f "$dir/bin/console" ]]; then echo symfony
    fi
}

# Reads {"queue_workers":[...],"schedule":[{"cron","cmd"}]} on stdin and
# stores it as the site's server-side lists (the override file, which
# wins over the repo — an empty list falls back to the repo's). Then
# installs them right away when the site is deployed: no deploy needed.
api_workers_set() {
    local name="$1" actor="$2"
    local parsed
    parsed="$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print("E\tthe body must be JSON"); sys.exit()
if not isinstance(d, dict):
    print("E\tthe body must be an object"); sys.exit()
def text(v, what):
    if not isinstance(v, str) or not v.strip():
        raise ValueError(what + " must be a non-empty string")
    v = v.strip()
    if len(v) > 500 or any(c in v for c in "\n\r\t\0"):
        raise ValueError(what + " must be one line, at most 500 characters")
    return v
try:
    w = d.get("queue_workers", [])
    s = d.get("schedule", [])
    if not isinstance(w, list) or not isinstance(s, list):
        raise ValueError("queue_workers and schedule must be lists")
    if len(w) > 20 or len(s) > 20:
        raise ValueError("at most 20 workers and 20 scheduled tasks")
    for i, c in enumerate(w):
        print("W\t" + text(c, "worker #%d" % i))
    for i, e in enumerate(s):
        if not isinstance(e, dict):
            raise ValueError("schedule #%d must be {cron, cmd}" % i)
        print("S\t" + text(e.get("cron"), "schedule #%d cron" % i) + "\t" + text(e.get("cmd"), "schedule #%d command" % i))
except ValueError as e:
    print("E\t" + str(e))
')"
    local -a workers=() crons=() cmds=()
    local kind a b
    while IFS=$'\t' read -r kind a b; do
        case "$kind" in
            E) api_die bad_request "$a" ;;
            W) workers+=("$a") ;;
            S) crons+=("$a"); cmds+=("$b") ;;
        esac
    done <<< "$parsed"
    local re='^[0-9*/,-]+[[:space:]]+[0-9*/,-]+[[:space:]]+[0-9*/,-]+[[:space:]]+[0-9*/,-]+[[:space:]]+[0-9*/,-]+$' i
    for ((i = 0; i < ${#crons[@]}; i++)); do
        [[ "${crons[$i]}" =~ $re ]] || api_die bad_request "schedule #$i: '${crons[$i]}' is not a 5-field cron expression (like '*/5 * * * *')"
        ! guardrail_match "${cmds[$i]}" || api_die bad_request "schedule #$i: the command mentions ddev or /var/www/html — those only exist in the local DDEV container"
    done
    for ((i = 0; i < ${#workers[@]}; i++)); do
        ! guardrail_match "${workers[$i]}" || api_die bad_request "worker #$i: the command mentions ddev or /var/www/html — those only exist in the local DDEV container"
    done

    local f; f="$(override_config_path "$name")"
    install -d -m 755 "$GENERATED_DIR"
    [[ -s "$f" ]] || printf '{}\n' > "$f"
    yq eval -i 'del(.queue_workers) | del(.schedule)' "$f"
    # Values go through the environment (strenv), never into the yq
    # expression: a command is free to contain quotes.
    for ((i = 0; i < ${#workers[@]}; i++)); do
        AW_V="${workers[$i]}" yq eval -i '.queue_workers += [strenv(AW_V)]' "$f"
    done
    for ((i = 0; i < ${#crons[@]}; i++)); do
        AW_C="${crons[$i]}" AW_M="${cmds[$i]}" yq eval -i '.schedule += [{"cron": strenv(AW_C), "cmd": strenv(AW_M)}]' "$f"
    done
    [[ "$(yq eval 'length' "$f" 2>/dev/null)" != "0" ]] || rm -f "$f"

    DDEPLOY_TRIGGER="web ($actor)" event_record "$name" "workers-config" succeeded "subject=${#workers[@]} worker(s), ${#crons[@]} scheduled task(s) set on the server"
    site_log "$name" "workers: server-side list set — ${#workers[@]} worker(s), ${#crons[@]} scheduled task(s) (web ($actor))"

    # Re-read the config (the override now wins) and install what it
    # says, the same calls a deploy makes. Not deployed yet: the first
    # deploy installs them.
    api_workers_config "$name"
    if [[ -L "$(site_root "$name")/current" ]]; then
        {
            install_queue_workers "$name" "$PHP_VERSION" "$(site_dir "$name")" "www-$name" "www-$name" "$(site_root "$name")" "${AW_QUEUE[@]}"
            install_schedule "$name" "$PHP_VERSION" "$(site_dir "$name")" "www-$name" "$(site_root "$name")" "${AW_SCHEDULE[@]}"
        } >&2 || api_die error "saved, but installing them failed — the next deploy retries"
        sleep 1
    fi
}

api_workers_json() {
    local name="$1"
    local preview=false
    is_preview "$name" && preview=true
    local paused=false
    [[ -f "$(schedule_paused_path "$name")" ]] && paused=true
    local override ext cfg_path
    override="$(override_config_path "$name")"
    ext="$(ext_config_path "$name")"
    cfg_path="$(resolve_config_path "$name")"
    local server_w server_s repo_w repo_s
    server_w="$(aw_workers_list "$override")"
    server_s="$(aw_schedule_list "$override")"
    repo_w="$(aw_workers_list "$ext")"; [[ "$repo_w" != "[]" ]] || repo_w="$(aw_workers_list "$cfg_path")"
    repo_s="$(aw_schedule_list "$ext")"; [[ "$repo_s" != "[]" ]] || repo_s="$(aw_schedule_list "$cfg_path")"
    local deployed=false
    [[ -L "$(site_root "$name")/current" ]] && deployed=true
    api_header
    printf ',"site":%s,"preview":%s,"schedules_paused":%s' "$(json_str "$name")" "$preview" "$paused"
    printf ',"framework":%s,"docroot":%s,"deployed":%s' "$(json_str_or_null "$(aw_framework "$name")")" "$(json_str "${DOCROOT:-}")" "$deployed"
    printf ',"sources":{"workers":%s,"schedules":%s}' \
        "$(json_str "$(aw_source "$server_w" "$repo_w")")" "$(json_str "$(aw_source "$server_s" "$repo_s")")"
    printf ',"server":{"queue_workers":%s,"schedule":%s},"repo":{"queue_workers":%s,"schedule":%s}' "$server_w" "$server_s" "$repo_w" "$repo_s"
    printf ',"workers":['

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

# api workers <name> [--restart|--stop|--start <index> | --set (JSON on stdin)] --actor <email>
api_workers() {
    local name="${1:-}"
    shift || true
    api_require_site "$name"
    local action="" index="" actor=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --restart|--stop|--start) action="${1#--}"; index="${2:-}"; shift ;;
            --set) action="set" ;;
            --actor) actor="${2:-}"; shift ;;
            *) api_die bad_request "workers: unknown option '$1'" ;;
        esac
        shift
    done
    if [[ "$action" == set ]]; then
        api_valid api_valid_actor "$actor"
        is_preview "$name" && api_die conflict "previews don't run queue workers or scheduled tasks"
        api_workers_set "$name" "$actor"
        api_workers_json "$name"
        return
    fi
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
