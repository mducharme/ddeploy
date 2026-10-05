#!/usr/bin/env bash
# The steps of a run (fetch code, composer, frontend build, go live...):
# names, timing, result. The web UI's run page shows them (with each
# step's own output, split on the marker lines) and says which one
# failed; `api run show` returns them.
#
#   $RUN_STEPS_DIR/<run id>.jsonl   one line per step start and end
#   $RUN_STEPS_DIR/<run id>.open    the step running now (a file, not a
#                                   variable: run_notifying runs the
#                                   command in a subshell, and reads this
#                                   back to know which step a failure hit)
# Outside a run (no DDEPLOY_RUN_ID, e.g. a function called directly),
# only the marker line is printed.

RUN_STEPS_DIR="$DDEPLOY_STATE/run-steps"

steps_path() {
    [[ "${DDEPLOY_RUN_ID:-}" =~ $RUN_ID_RE ]] || return 1
    printf '%s/%s' "$RUN_STEPS_DIR" "$DDEPLOY_RUN_ID"
}

# $1 id (a-z0-9-), $2 label. Ends the step before it (ok).
step_begin() {
    local id="$1" label="$2" base
    [[ "$id" =~ ^[a-z0-9-]{1,40}$ ]] || return 0
    label="${label//$'\n'/ }"
    label="${label:0:120}"
    # A log line like any other (time and [info] in a detached run's log),
    # on stderr: callers may have stdout captured, and the run log gets both.
    log_info "==> [$id] $label"
    base="$(steps_path)" || return 0
    [[ "$EUID" -eq 0 ]] || return 0
    step_end ok
    mkdir -p "$RUN_STEPS_DIR"
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\t%s\t%s\t%s\n' "$id" "$(date +%s)" "$now" "$label" > "$base.open"
    printf '{"id":%s,"label":%s,"status":"running","started_at":%s}\n' "$(json_str "$id")" "$(json_str "$label")" "$(json_str "$now")" >> "$base.jsonl"
}

# $1 ok|failed|skipped: ends the step running now, if any.
step_end() {
    local status="$1" base id t started label
    base="$(steps_path)" || return 0
    [[ -f "$base.open" ]] || return 0
    IFS=$'\t' read -r id t started label < "$base.open"
    rm -f "$base.open"
    printf '{"id":%s,"label":%s,"status":%s,"started_at":%s,"duration_s":%s}\n' \
        "$(json_str "$id")" "$(json_str "$label")" "$(json_str "$status")" "$(json_str "$started")" "$(( $(date +%s) - t ))" >> "$base.jsonl"
}

# The label of the step running now (what a failure hit), or nothing.
step_open_label() {
    local base id t started label
    base="$(steps_path)" || return 0
    [[ -f "$base.open" ]] || return 0
    IFS=$'\t' read -r id t started label < "$base.open"
    printf '%s' "$label"
}

# Whether the run got past going live (the "switch" step ended ok).
steps_went_live() {
    local base; base="$(steps_path)" || return 1
    grep -q '"id":"switch","label":[^}]*"status":"ok"' "$base.jsonl" 2>/dev/null
}

# A run's steps, start and end lines folded into one per step, as a JSON
# array (an old run without steps: []).
steps_json() {
    local file="$RUN_STEPS_DIR/$1.jsonl"
    [[ -f "$file" ]] || { printf '[]'; return; }
    python3 - "$file" <<'PY'
import json, sys
steps, index = [], {}
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        s = json.loads(line)
    except ValueError:
        continue
    key = s["id"]
    if s.get("status") == "running" or key not in index:
        index[key] = len(steps)
        steps.append(s)
    else:
        steps[index[key]] = s
print(json.dumps(steps, separators=(",", ":")))
PY
}

prune_run_steps() {
    [[ -d "$RUN_STEPS_DIR" ]] || return 0
    find "$RUN_STEPS_DIR" -maxdepth 1 -type f -mtime +"${RUN_LOG_RETENTION_DAYS:-30}" -delete 2>/dev/null || true
}
