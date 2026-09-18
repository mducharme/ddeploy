#!/usr/bin/env bash
# Hook replay: executes a site's normalized deploy steps
# ($GENERATED_DIR/<name>.steps, written by config.sh) as the site's own
# Linux user, under its pinned PHP version.

guardrail_match() {
    local cmd="$1"
    [[ "$cmd" == *ddev* || "$cmd" == *"/var/www/html"* ]]
}

# Reports guardrail hits without running anything — used at provision
# time so a non-conforming repo is caught at setup, not mid-deploy.
scan_hooks() {
    local name="$1"
    local steps="$GENERATED_DIR/$name.steps"
    [[ -f "$steps" ]] || return 0
    local type cmd
    while IFS=$'\t' read -r type cmd; do
        [[ -z "$type" ]] && continue
        if guardrail_match "$cmd"; then
            log_warn "guardrail: step '$type: $cmd' references ddev/a container path — will be SKIPPED at deploy time"
        fi
        if [[ "$type" == "exec-host" ]]; then
            log_warn "host-context step ('$cmd') — runs outside the site's isolation boundary, review before trusting"
        fi
    done < "$steps"
}

# $4/$5 (optional) exec user/home — default to the site's own www-<name>.
# A shared-mode preview passes its parent's user/dir instead, since its
# deploy steps (a migration, notably) run as whoever actually owns the
# database they're pointed at.
replay_hooks() {
    local name="$1" php="$2" dir="$3"
    local exec_user="${4:-www-$name}" exec_home="${5:-$dir}"
    local steps="$GENERATED_DIR/$name.steps"
    [[ -f "$steps" ]] || { log_info "no deploy steps for $name"; return 0; }

    local shim; shim="$(ensure_php_shim "$php")"
    local type cmd
    while IFS=$'\t' read -r type cmd; do
        [[ -z "$type" ]] && continue
        if guardrail_match "$cmd"; then
            log_warn "skipping step '$type: $cmd' — ddev/container-path reference"
            site_log "$name" "deploy: SKIPPED (guardrail) $type: $cmd"
            continue
        fi
        case "$type" in
            exec)
                log_info "exec ($name, php$php): $cmd"
                site_log "$name" "deploy: exec: $cmd"
                sudo -u "$exec_user" env HOME="$exec_home" PATH="$shim:/usr/bin:/bin" bash -lc "cd '$dir' && $cmd"
                ;;
            composer)
                log_info "composer ($name, php$php): $cmd"
                site_log "$name" "deploy: composer: $cmd"
                sudo -u "$exec_user" env HOME="$exec_home" PATH="$shim:/usr/bin:/bin" bash -lc "cd '$dir' && composer $cmd"
                ;;
            exec-host)
                log_warn "exec-host step skipped by default — host-context command, review before trusting: $cmd"
                site_log "$name" "deploy: SKIPPED (exec-host, review manually) $cmd"
                ;;
            *)
                log_warn "unknown hook type '$type', skipping"
                ;;
        esac
    done < "$steps"
}
