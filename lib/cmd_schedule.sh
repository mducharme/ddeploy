#!/usr/bin/env bash
# `schedule-run <name> <index>`: what a site's cron.d line runs (as root)
# for one of its `schedule` entries (lib/queue.sh). It:
#   - skips while the site's schedules are paused (`api schedules --pause`),
#   - skips while the previous run of the same entry is still going
#     (flock) — a slow `queue/run` every 5 minutes never piles up,
#   - runs the generated wrapper as the site user (runuser),
#   - appends its output to $LOG_DIR/<name>.schedule-<index>.log, and
#   - records the last run (start, end, exit code) for the web UI.
# Started from the web UI ("Run now", `api run start schedule-run`) it
# also prints the output, which becomes that run's log.

SCHEDULE_STATE_DIR="$DDEPLOY_STATE/schedules"

schedule_log_path() { printf '%s/%s.schedule-%s.log' "$LOG_DIR" "$1" "$2"; }
schedule_state_path() { printf '%s/%s-%s.json' "$SCHEDULE_STATE_DIR" "$1" "$2"; }
schedule_lock_path() { printf '%s/%s-%s.lock' "$SCHEDULE_STATE_DIR" "$1" "$2"; }
schedule_paused_path() { printf '%s/%s.paused' "$SCHEDULE_STATE_DIR" "$1"; }

# True while a run of $1 #$2 holds its lock.
schedule_is_running() {
    local lock; lock="$(schedule_lock_path "$1" "$2")"
    [[ -f "$lock" ]] || return 1
    ! flock -n "$lock" true 2>/dev/null
}

# $1 name $2 index, then key=value fields: the last run, as JSON, atomically.
schedule_record() {
    local name="$1" index="$2"; shift 2
    local out="{" first=1 kv k v
    for kv in "$@"; do
        k="${kv%%=*}" v="${kv#*=}"
        [[ "$first" -eq 1 ]] || out+=","
        first=0
        if [[ "$v" =~ ^-?[0-9]+$ || "$v" == null ]]; then out+="\"$k\":$v"; else out+="\"$k\":$(json_str "$v")"; fi
    done
    out+="}"
    install -d -m 755 "$SCHEDULE_STATE_DIR"
    local tmp; tmp="$(mktemp "$SCHEDULE_STATE_DIR/.state.XXXXXX")"
    printf '%s\n' "$out" > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$(schedule_state_path "$name" "$index")"
}

cmd_schedule_run() {
    load_conf
    require_root
    local name="${1:-}" index="${2:-}"
    validate_name "$name"
    [[ "$index" =~ ^[0-9]{1,2}$ ]] || die "schedule index must be a number"
    local script="$GENERATED_DIR/$name.schedule-$index.sh"
    [[ -f "$script" ]] || die "'$name' has no schedule #$index (deploy it to install its schedule)"
    local log; log="$(schedule_log_path "$name" "$index")"
    local trigger; trigger="$(notify_trigger)"
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    install -d -m 755 "$SCHEDULE_STATE_DIR"
    # From the web UI (a run of its own): the output goes to that run's log too.
    local echo_out=0
    [[ -n "${DDEPLOY_RUN_ID:-}" ]] && echo_out=1

    if [[ -f "$(schedule_paused_path "$name")" && "$echo_out" -eq 0 ]]; then
        log_line "$log" info "skipped: schedules are paused for $name"
        return 0
    fi

    local lock; lock="$(schedule_lock_path "$name" "$index")"
    exec 9>>"$lock"
    if ! flock -n 9; then
        log_line "$log" warn "skipped: the previous run is still going"
        [[ "$echo_out" -eq 0 ]] || die "schedule #$index of '$name' is already running — wait for it to finish"
        return 0
    fi

    local started="$SECONDS" rc=0
    schedule_record "$name" "$index" "started_at=$now" "finished_at=null" "exit_code=null" "duration_s=null" "trigger=$trigger"
    # ddeploy's own lines around the command's output (which is the
    # project's, untagged): when it started, and how it ended.
    log_line "$log" info "started ($trigger)"
    if [[ "$echo_out" -eq 1 ]]; then
        log_info "running schedule #$index of $name: $(tail -n 1 "$script")"
        runuser -u "www-$name" -- "$script" 2>&1 | tee -a "$log" || rc=$?
    else
        runuser -u "www-$name" -- "$script" >> "$log" 2>&1 || rc=$?
    fi
    local duration=$((SECONDS - started))
    if [[ "$rc" -eq 0 ]]; then
        log_line "$log" ok "finished: exit 0, ${duration}s"
    else
        log_line "$log" error "finished: exit $rc, ${duration}s"
    fi
    schedule_record "$name" "$index" "started_at=$now" "finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" "exit_code=$rc" "duration_s=$duration" "trigger=$trigger"
    flock -u 9
    if [[ "$echo_out" -eq 1 ]]; then
        event_attr kind schedule-run
        event_attr subject "schedule #$index: exit $rc in ${duration}s"
        [[ "$rc" -eq 0 ]] || die "schedule #$index of '$name' exited $rc"
    fi
    return 0
}
