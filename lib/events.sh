#!/usr/bin/env bash
# Structured event log + per-run output logs: what the `api` subcommand
# (and so the web UI) reads deploy and preview history from.
#
#   $EVENTS_DIR/<site>.jsonl    one JSON object per line, appended as a
#                               run starts and as it ends:
#     {ts, run_id, site, kind, phase, trigger, ...}
#     kind   deploy|rollback|provision|provision-preview|deploy-preview|remove-preview
#     phase  started|succeeded|failed|skipped
#     extra  from_sha to_sha subject author branch project duration_s error
#            (author: the deployed commit's git author)
#   $RUNS_LOG_DIR/<run-id>.log  the run's full output (stdout + stderr)
#   $RUNS_META_DIR/<run-id>.json  only for runs started through
#                               `api run start` (who asked, for what)
#
# .deploys (lib/deploy_history.sh) stays as it is — rollback reads it;
# this is additional, not a replacement. Previews are covered here even
# though they aren't in .deploys.
#
# A run's start/end events are written by run_notifying (provision.sh),
# which wraps every deploy-type command. Details only the command itself
# knows (the SHAs, "this was a rollback", "skipped: already up to date")
# reach it through event_attr: the command runs in a subshell, so plain
# variables wouldn't survive back to the wrapper.

EVENTS_DIR="$DDEPLOY_STATE/events"
RUNS_META_DIR="$DDEPLOY_STATE/runs"
RUNS_LOG_DIR="$LOG_DIR/runs"
RUN_ID_RE='^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$'

# 20261002T143012Z-3fa9c1 — sorts by time, unique enough for one server.
new_run_id() {
    printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
}

validate_run_id() {
    [[ "$1" =~ $RUN_ID_RE ]] || die "invalid run id '$1'"
}

# $1 site, $2 kind, $3 phase, rest key=value extras (duration_s is
# emitted as a number, everything else as a string; empty values are
# left out). Never fails the caller: history is best effort, a deploy
# must not break because /var/lib is full.
event_record() {
    local site="$1" kind="$2" phase="$3"; shift 3
    # The site name becomes a path: never anything but a plain name.
    [[ "$site" =~ $NAME_RE ]] || return 0
    local line kv key val
    line="{\"ts\":$(json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    line+=",\"run_id\":$(json_str_or_null "${DDEPLOY_RUN_ID:-}")"
    line+=",\"site\":$(json_str "$site"),\"kind\":$(json_str "$kind"),\"phase\":$(json_str "$phase")"
    line+=",\"trigger\":$(json_str "$(notify_trigger)")"
    for kv in "$@"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        [[ -n "$val" && "$key" =~ ^[a-z_]+$ ]] || continue
        if [[ "$key" == duration_s ]]; then
            line+=",\"$key\":$(json_num "$val")"
        else
            line+=",\"$key\":$(json_str "$val")"
        fi
    done
    line+="}"
    {
        mkdir -p "$EVENTS_DIR"
        chmod 700 "$EVENTS_DIR"
        printf '%s\n' "$line" >> "$EVENTS_DIR/$site.jsonl"
        events_trim "$EVENTS_DIR/$site.jsonl"
    } 2>/dev/null || true
}

# Keeps an events file bounded: past EVENTS_MAX_BYTES it's cut down to
# its newest EVENTS_KEEP_LINES lines (thousands of runs — years for most
# sites). Readers only ever want recent history; .deploys keeps the full
# SHA log rollback needs.
EVENTS_MAX_BYTES=2000000
EVENTS_KEEP_LINES=4000
events_trim() {
    local f="$1" size
    size="$(wc -c < "$f" 2>/dev/null || echo 0)"
    (( ${size//[[:space:]]/} > EVENTS_MAX_BYTES )) || return 0
    local tmp; tmp="$(mktemp "$f.XXXXXX")"
    tail -n "$EVENTS_KEEP_LINES" "$f" > "$tmp" && mv "$tmp" "$f" || rm -f "$tmp"
}

# Called from inside a deploy-type command: hands key=value $1=$2 to the
# run_notifying wrapper for the run's final event. No-op outside one.
event_attr() {
    [[ -n "${DDEPLOY_EVENT_ATTRS:-}" ]] || return 0
    printf '%s=%s\n' "$1" "${2//$'\n'/ }" >> "$DDEPLOY_EVENT_ATTRS" 2>/dev/null || true
}

# Prints the value of key $2 from attrs file $1 (last one wins), or $3.
event_attr_get() {
    local file="$1" key="$2" default="${3:-}" val=""
    [[ -f "$file" ]] && val="$(awk -v k="$key" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$file")"
    printf '%s' "${val:-$default}"
}

# Removes run logs (and run metadata) older than RUN_LOG_RETENTION_DAYS.
# Called at the start of every run, so it needs no cron entry of its own.
prune_run_logs() {
    local days="${RUN_LOG_RETENTION_DAYS:-30}"
    [[ "$days" =~ ^[1-9][0-9]{0,3}$ ]] || days=30
    find "$RUNS_LOG_DIR" -maxdepth 1 -type f -name '*.log' -mtime +"$days" -delete 2>/dev/null || true
    find "$RUNS_META_DIR" -maxdepth 1 -type f \( -name '*.json' -o -name '*.cancelled' \) -mtime +"$days" -delete 2>/dev/null || true
}

# A backup of one site, from inside the fleet-wide backup-uploads /
# backup-database loop: its own event (cron runs have no run of their
# own), or — when the whole command is a single-site run under
# run_notifying (`api run start backup-*`) — details for that run's event.
backup_event() {
    local site="$1" kind="$2" phase="$3"; shift 3
    if [[ -n "${DDEPLOY_EVENT_ATTRS:-}" ]]; then
        local kv
        for kv in "$@"; do [[ "$kv" == subject=* ]] && event_attr subject "${kv#subject=}"; done
        return 0
    fi
    event_record "$site" "$kind" "$phase" "$@"
}
