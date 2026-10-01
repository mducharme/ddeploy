#!/usr/bin/env bash
# Hook replay: executes a site's normalized deploy steps
# ($GENERATED_DIR/<name>.steps, written by config.sh) as the site's own
# Linux user, under its pinned PHP version and resolved Node version
# (lib/node.sh). A `node` step is the frontend build parse_config
# inserted from `build:` (or auto-detected) — its parameters are the
# BUILD_* globals, not the step's own text, which is just a label.

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

# A failed exec/composer step: one clear line saying the deploy stopped
# and why, with the step's last lines of output under it in the site log
# ($4, from run_captured). The [error] line is also what the failure
# notification quotes.
deploy_step_failed() {
    local name="$1" rc="$2" what="$3" out="${4:-}"
    site_log "$name" "deploy: step FAILED (exit $rc): $what"
    [[ -n "$out" ]] && site_log_output "$name" "$out"
    rm -f "$out"
    die "'$name': deploy step failed (exit $rc): $what — the deploy stopped here (see the output above, or 'ddeploy logs $name')"
}

# $4/$5 (optional) exec user/home — default to the site's own www-<name>.
# A shared-mode preview passes its parent's user/dir instead, since its
# deploy steps (a migration, notably) run as whoever actually owns the
# database they're pointed at. Reads DEPLOY_SSH_AUTH_SOCK (set by
# start_deploy_ssh_agent, lib/git_access.sh) if the caller started one —
# threaded into exec/composer steps so a private VCS dependency still
# resolves, without any key ever living in $exec_user's own $HOME.
replay_hooks() {
    local name="$1" php="$2" dir="$3"
    local exec_user="${4:-www-$name}" exec_home="${5:-$dir}"
    local steps="$GENERATED_DIR/$name.steps"
    [[ -f "$steps" ]] || { log_info "no deploy steps for $name"; return 0; }

    # Node on PATH for every step, not just the `node` build step — an
    # `exec: npm run build` in hooks.post-start is how most DDEV projects
    # already declare their build.
    prepare_site_node "$name"
    local path; path="$(toolchain_path "$php")"
    local type cmd out
    # Each step's command runs with </dev/null: this loop reads the steps
    # file on stdin, and a step that reads stdin would otherwise swallow
    # the remaining steps, which then silently never run. And with
    # COMPOSER_NO_INTERACTION=1, so composer (in a composer step, or an
    # exec step calling it) fails clearly instead of waiting on a prompt.
    while IFS=$'\t' read -r type cmd; do
        [[ -z "$type" ]] && continue
        if guardrail_match "$cmd"; then
            log_warn "skipping step '$type: $cmd' — ddev/container-path reference"
            site_log "$name" "deploy: SKIPPED (guardrail) $type: $cmd"
            continue
        fi
        case "$type" in
            exec)
                log_info "exec ($name, php$php${NODE_VERSION:+, node $NODE_VERSION}): $cmd"
                site_log "$name" "deploy: exec: $cmd"
                out="$(mktemp)"
                run_captured "$out" sudo -u "$exec_user" env HOME="$exec_home" PATH="$path" SSH_AUTH_SOCK="${DEPLOY_SSH_AUTH_SOCK:-}" COMPOSER_NO_INTERACTION=1 bash -lc "cd '$dir' && $cmd" </dev/null \
                    || deploy_step_failed "$name" "$?" "$cmd" "$out"
                rm -f "$out"
                ;;
            composer)
                log_info "composer ($name, php$php): $cmd"
                site_log "$name" "deploy: composer: $cmd"
                out="$(mktemp)"
                run_captured "$out" sudo -u "$exec_user" env HOME="$exec_home" PATH="$path" SSH_AUTH_SOCK="${DEPLOY_SSH_AUTH_SOCK:-}" COMPOSER_NO_INTERACTION=1 bash -lc "cd '$dir' && composer $cmd" </dev/null \
                    || deploy_step_failed "$name" "$?" "composer $cmd" "$out"
                rm -f "$out"
                ;;
            node)
                run_node_build "$name" "$dir" "$exec_user" "$exec_home" "$path"
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
