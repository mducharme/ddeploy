#!/usr/bin/env bash
# `api <verb> [args]` — the machine-readable interface the web UI
# (webddeploy) drives ddeploy through. Every verb prints one JSON object
# on stdout ({"api_version": 1, ...}); on failure, an
# {"api_version": 1, "error": {"code", "message"}} object and exit 1.
#
# This is the web UI's entire privilege boundary: its unprivileged user
# gets exactly one sudoers rule, `provision.sh api *` (lib/cmd_init_web.sh),
# so everything reachable from the web is what's dispatched here. Hence:
#   - an explicit verb allowlist (api_dispatch); anything else is refused
#   - every argument validated with the same validators the CLI uses,
#     before anything is touched; no argument ever reaches a shell
#   - read verbs never change state; the only mutating verb is
#     `run start`, for deploy and provision only, and provision accepts
#     a fixed set of flags (no --deploy-cmd: that's free text that gets
#     executed, and projects declare deploy steps in their repo instead)
# Not reachable from here on purpose (see the plan in webddeploy):
# env, override, remove, restore-*, init*, configure, node-gc.

API_VERSION=1
API_ACTOR_RE='^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}$'
API_REPO_URL_RE='^(ssh://|https://|git@)[A-Za-z0-9._~:/@%+-]+$'
API_MAX_READ_BYTES=524288

usage_api() {
    cat <<'EOF'
usage: ddeploy api <verb> [args]

JSON interface for the web UI. Every verb prints one JSON object.

read:
  info                                  server, ddeploy version, features
  sites                                 every provisioned site (previews included)
  site-names                            just their names (and which are previews): instant, for a list to show first
  site <name>                           one site: summary, resolved config, releases
  events [--site n] [--project p] [--run id] [--limit N]
                                        deploy/preview event log, oldest first
  previews <project>                    active previews of a project
  doctor [name]                         health checks (never pages NOTIFY_WEBHOOK)
  logs [<name> [--lines N | --offset B]]   list logs, or read one: <site>, <site>.access,
                                        <site>.error, nginx_access, nginx_error, phpX.Y_fpm, webhook...
  inspect-repo <url> [--branch b]       what provision would find in a repo
  run show <id>                         a run's metadata, events and unit state
  run log <id> [--lines N | --offset B] a run's full output

  env <name>                            the site's .env entries (values included)
  branches <name>                       branches of the site's repository
  commits <name> <from-sha> <to-sha>    commits between two deploys
  db info <name>                        database size, tables, snapshots
  db credentials <name>                 the site's own DB connection details
  db dump <name> [--snapshot <id>]      gzipped SQL on stdout (not JSON)
  uploads <name>                        upload dirs (size, file count) and their snapshots
  uploads download <name> --dir <d>     a .tar.gz of one upload dir on stdout (not JSON)
  backups <name>                        object-storage backups: dumps, file mirror + versions, retention
  backups download <name> --file <dump> one backed-up dump on stdout (not JSON)
  fetch-key                             the key for copying files from another server (created if missing)
  files <name> [--read <path>]          persistent config files (charcoal's config.local.json, persistent_files)

write (each needs --actor <email>):
  env <name> --apply [--unset KEY]...   set the KEY=value lines read from stdin
  settings <name> [--set key=value]... [--unset key]... [--branch b | --clear-branch]
                                        operator overrides + tracked branch
  run cancel <id>                       stop a run started with run start
  run start deploy <name> --actor <email>
  run start rollback <name> [--sha <sha>] --actor <email>
  run start db-import <name> --actor <email>     the dump (.sql or .sql.gz) on stdin
  run start db-restore <name> --snapshot <id> --actor <email>
  run start db-snapshot <name> --actor <email>
  run start preview-create <project> --branch <b> [--shared|--isolated] [--no-seed] [--auth|--no-auth] --actor <email>
  run start preview-deploy <project> --branch <b> --actor <email>
  run start preview-remove <project> --branch <b> --actor <email>   (its files, and its DB if isolated)
  run start uploads-import <name> --dir <d> [--mode merge|replace] --actor <email>   archive on stdin
  run start uploads-restore <name> --snapshot <id> --actor <email>
  run start uploads-fetch <name> --dir <d> --source <user@host:path> [--port n] [--mode merge|replace] --actor <email>
  fetch-test <name> --source <user@host:path> [--port n] [--accept <SHA256:fp>] --actor <email>
                                        check the host key (remember it with --accept) and dry-run
  fetch-key forget --host <h> [--port n] --actor <email>
  files <name> --write <path> [--expect-sha s] --actor <email>   new content on stdin; checked, previous kept
  files <name> --restore <path> --version <id> --actor <email>
  run start uploads-snapshot <name> --actor <email>
  run start backup-database|backup-uploads <name> --actor <email>   back up now
  run start backup-restore-db <name> --file <dump> --actor <email>
  run start backup-restore-uploads <name> --dir <d> [--version <run>] --actor <email>
  backups keep|unkeep|delete <name> --file <dump> --actor <email>   keep = never pruned
  config                                server settings the web UI may change (provisioner.conf)
  config set --actor <email>            KEY=value lines on stdin; validated, backed up, applied
  run start provision <name> <repo-url> --actor <email> [--branch b] [--php X.Y]
      [--docroot p] [--db name] [--hostnames "a b"] [--custom-domains "a b"]
      [--upload-dirs "a b"] [--auth|--no-auth] [--node v] [--build|--no-build]
                                        start a detached run; prints its id
EOF
}

cmd_api() {
    case "${1:-}" in -h|--help|help|"") usage_api; return 0 ;; esac
    # Binary output: streamed, never captured into a variable (NUL bytes).
    # Errors still come out as the usual JSON object, before any output.
    if [[ "${1:-}" == db && "${2:-}" == dump ]]; then
        shift 2
        api_db_dump "$@"
        return
    fi
    if [[ "${1:-}" == backups && "${2:-}" == download ]]; then
        shift 2
        api_backups_download "$@"
        return
    fi
    if [[ "${1:-}" == uploads && "${2:-}" == download ]]; then
        shift 2
        api_uploads_download "$@"
        return
    fi
    local errf codef out rc
    errf="$(mktemp)"
    codef="$(mktemp)"
    # Not `out="$(...)" || rc=$?`: bash ignores errexit inside anything on
    # the left of ||, so a failing validator wouldn't stop the verb.
    set +e
    out="$(API_ERR_CODE_FILE="$codef"; set -e; api_dispatch "$@" 2>"$errf")"
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
        printf '%s\n' "$out"
    else
        local msg code
        msg="$(sed 's/\x1b\[[0-9;]*m//g' "$errf" | grep -E '^\[error\]' | tail -n 1 | sed 's/^\[error\] *//' || true)"
        [[ -n "$msg" ]] || msg="$(tail -n 1 "$errf")"
        [[ -n "$msg" ]] || msg="api $1 failed (exit $rc)"
        code="$(cat "$codef" 2>/dev/null)"
        printf '{"api_version":%s,"error":{"code":%s,"message":%s}}\n' \
            "$API_VERSION" "$(json_str "${code:-error}")" "$(json_str "$msg")"
        cat "$errf" >&2
    fi
    rm -f "$errf" "$codef"
    return "$rc"
}

# $1 code (bad_request|not_found|conflict|unknown_verb|unavailable), rest message.
api_die() {
    local code="$1"; shift
    [[ -n "${API_ERR_CODE_FILE:-}" ]] && printf '%s' "$code" > "$API_ERR_CODE_FILE"
    die "$*"
}

# Runs validator "$@"; a failure becomes a bad_request with its message.
api_valid() {
    local msg
    msg="$( ("$@") 2>&1 >/dev/null )" || api_die bad_request "$(sed 's/^\[error\] *//' <<< "$msg" | tail -n 1)"
}

api_dispatch() {
    local verb="$1"; shift
    case "$verb" in
        info|sites|site-names|site|events|previews|doctor|logs|inspect-repo|run|env|settings|branches|commits|db|uploads|backups|config|fetch-key|fetch-test|files) ;;
        *) api_die unknown_verb "unknown api verb '$verb'" ;;
    esac
    load_conf
    require_root
    PARSE_CONFIG_QUIET=1
    case "$verb" in
        info)         api_info "$@" ;;
        sites)        api_sites "$@" ;;
        site-names)   api_site_names "$@" ;;
        site)         api_site "$@" ;;
        events)       api_events "$@" ;;
        previews)     api_previews "$@" ;;
        doctor)       api_doctor "$@" ;;
        logs)         api_logs "$@" ;;
        inspect-repo) api_inspect_repo "$@" ;;
        run)          api_run "$@" ;;
        env)          api_env "$@" ;;
        settings)     api_settings "$@" ;;
        branches)     api_branches "$@" ;;
        commits)      api_commits "$@" ;;
        db)           api_db "$@" ;;
        uploads)      api_uploads "$@" ;;
        backups)      api_backups "$@" ;;
        config)       api_config "$@" ;;
        fetch-key)    api_fetch_key "$@" ;;
        fetch-test)   api_fetch_test "$@" ;;
        files)        api_files "$@" ;;
    esac
}

api_header() { printf '{"api_version":%s' "$API_VERSION"; }

# $1 a positive integer argument, $2 its default, $3 its maximum, $4 label.
api_int() {
    local val="${1:-$2}" max="$3" label="$4"
    [[ "$val" =~ ^[0-9]{1,9}$ ]] || api_die bad_request "$label must be a non-negative integer"
    (( val <= max )) || val="$max"
    printf '%s' "$val"
}

# --- site-names -----------------------------------------------------------

# What `sites` would list, without reading any config or git: the web UI
# shows these at once and fills in the details when `sites` answers.
api_site_names() {
    [[ $# -eq 0 ]] || api_die bad_request "site-names takes no arguments"
    api_header
    printf ',"sites":['
    local name first=1 preview
    while IFS= read -r name; do
        preview=null
        if is_preview "$name" && read_preview_meta "$name" 2>/dev/null; then
            preview="{\"project\":$(json_str "$PREVIEW_PROJECT")}"
        fi
        [[ "$first" -eq 1 ]] || printf ','
        first=0
        printf '{"name":%s,"preview":%s}' "$(json_str "$name")" "$preview"
    done < <(provisioned_site_names)
    printf ']}\n'
}

# --- info ---------------------------------------------------------------

api_info() {
    [[ $# -eq 0 ]] || api_die bad_request "info takes no arguments"
    local sha branch
    sha="$(git -c safe.directory='*' -C "$PROVISIONER_DIR" rev-parse HEAD 2>/dev/null || true)"
    branch="$(git -c safe.directory='*' -C "$PROVISIONER_DIR" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    local -a installed=()
    local d
    for d in /etc/php/*/fpm; do
        [[ -d "$d" ]] && installed+=("$(basename "$(dirname "$d")")")
    done
    local -a baseline=()
    read -r -a baseline <<< "$BASELINE_PHP"
    api_header
    printf ',"hostname":%s' "$(json_str "$(hostname -f 2>/dev/null || hostname)")"
    printf ',"ddeploy":{"sha":%s,"branch":%s}' "$(json_str_or_null "$sha")" "$(json_str_or_null "$branch")"
    printf ',"base_domain":%s' "$(json_str "$BASE_DOMAIN")"
    printf ',"php":{"default":%s,"baseline":%s,"installed":%s}' \
        "$(json_str "$DEFAULT_PHP")" "$(json_str_array "${baseline[@]}")" "$(json_str_array "${installed[@]}")"
    printf ',"node":{"enabled":%s,"default":%s}' "$(json_bool "$NODE_ENABLED")" "$(json_str "$DEFAULT_NODE")"
    printf ',"features":{"webhook":%s,"backups":%s,"db_backups":%s,"preview_prune":%s,"web":%s}' \
        "$(json_bool "$WEBHOOK_ENABLED")" "$(json_bool "$BACKUP_ENABLED")" "$(json_bool "$DB_BACKUP_ENABLED")" \
        "$(json_bool "$PREVIEW_PRUNE_ENABLED")" "$(json_bool "${WEB_ENABLED:-false}")"
    printf ',"preview_db_mode":%s' "$(json_str "$PREVIEW_DB_MODE")"
    printf ',"basic_auth_default":%s' "$(json_bool "$BASIC_AUTH_DEFAULT")"
    printf ',"defaults":{"client_max_body_size":%s,"fpm_max_children":%s,"db_backup_retention_days":%s}' \
        "$(json_str "$CLIENT_MAX_BODY_SIZE")" "$(json_str "$FPM_MAX_CHILDREN")" "$(json_str "$DB_BACKUP_RETENTION_DAYS")"
    printf ',"limits":{"db_import_max_bytes":%s,"uploads_import_max_bytes":%s}' "$(api_import_max_bytes)" "$(api_upload_max_bytes)"
    printf ',"backups":{"bucket":%s,"database":{"enabled":%s,"schedule":%s,"retention_days":%s},"uploads":{"enabled":%s,"schedule":%s,"versions_days":%s}}' \
        "$(json_str_or_null "$BACKUP_BUCKET")" "$(json_bool "$DB_BACKUP_ENABLED")" "$(json_str "$DB_BACKUP_SCHEDULE")" "$(json_num "$DB_BACKUP_RETENTION_DAYS")" \
        "$(json_bool "$BACKUP_ENABLED")" "$(json_str "$BACKUP_SCHEDULE")" "$(json_num "$UPLOADS_BACKUP_VERSIONS_DAYS")"
    printf '}\n'
}

api_upload_max_bytes() {
    local mb="${WEB_UPLOAD_MAX_MB:-10240}"
    [[ "$mb" =~ ^[1-9][0-9]{0,6}$ ]] || mb=10240
    printf '%s' "$(( mb * 1024 * 1024 ))"
}

api_import_max_bytes() {
    local mb="${WEB_IMPORT_MAX_MB:-2048}"
    [[ "$mb" =~ ^[1-9][0-9]{0,5}$ ]] || mb=2048
    printf '%s' "$(( mb * 1024 * 1024 ))"
}

# --- sites / site -------------------------------------------------------

# One site's summary object on one line: list's columns plus what the UI
# links to (URL, repo, full SHA) and the newest event.
api_site_summary() {
    local name="$1"
    local row php="" node="" docroot="" db="" branch="" sha="" when="" preview=""
    row="$(list_row "$name" 2>/dev/null)" || true
    IFS=$'\x1f' read -r _ php node docroot db branch sha when preview <<< "$row"

    local build=false node_spec="$node"
    if [[ "$node" == *+build ]]; then
        build=true
        node_spec="${node%+build}"
    fi
    [[ "$node_spec" == "-" || "$node_spec" == "?" ]] && node_spec=""
    [[ "$php" == "?" ]] && php=""
    [[ "$branch" == "-" ]] && branch=""

    local checkout full_sha="" committed_at="" subject="" repo=""
    checkout="$(site_dir "$name")"
    if [[ -d "$checkout/.git" ]]; then
        local last
        last="$(git -c safe.directory='*' -C "$checkout" log -1 --format='%H%x1f%cI%x1f%s' 2>/dev/null || true)"
        [[ -n "$last" ]] && IFS=$'\x1f' read -r full_sha committed_at subject <<< "$last"
        repo="$(git -c safe.directory='*' -C "$checkout" remote get-url origin 2>/dev/null || true)"
    fi

    local preview_json=null
    if is_preview "$name" && read_preview_meta "$name" 2>/dev/null; then
        preview_json="{\"project\":$(json_str "$PREVIEW_PROJECT"),\"branch\":$(json_str "$PREVIEW_BRANCH"),\"mode\":$(json_str "$PREVIEW_MODE")}"
    fi

    local last_event=null last_run=null last_deploy=null f="$EVENTS_DIR/$name.jsonl"
    if [[ -s "$f" ]]; then
        last_event="$(tail -n 1 "$f")"
        # Config changes are events but not runs: "last run" skips them.
        last_run="$(grep -v -e '"kind":"env-change"' -e '"kind":"settings-change"' -e '"kind":"file-change"' -e '"kind":"backup-' "$f" | tail -n 1 || true)"
        last_deploy="$(grep -E '"kind":"(deploy|rollback|provision|provision-preview|deploy-preview)","phase":"succeeded"' "$f" | tail -n 1 || true)"
        [[ -n "$last_run" ]] || last_run=null
        [[ -n "$last_deploy" ]] || last_deploy=null
    fi
    # When the live code went live: the newest successful deploy event,
    # else (history from before the event log) .deploys' newest entry, or
    # a preview's deployed-sha marker.
    local deployed_at=""
    if [[ "$last_deploy" != null ]]; then
        deployed_at="$(sed -E 's/^\{"ts":"([^"]+)".*/\1/' <<< "$last_deploy")"
    elif [[ -s "$(deploy_history_path "$name")" ]]; then
        deployed_at="$(tail -n 1 "$(deploy_history_path "$name")" | cut -f1)"
    elif [[ -f "$(preview_deployed_path "$name")" ]]; then
        deployed_at="$(date -u -d "@$(stat -c %Y "$(preview_deployed_path "$name")")" +%Y-%m-%dT%H:%M:%SZ)"
    fi

    printf '{"name":%s,"url":%s,"php":%s,"node":%s,"build":%s,"docroot":%s,"db":%s,"branch":%s' \
        "$(json_str "$name")" "$(json_str "https://$name.$BASE_DOMAIN")" "$(json_str_or_null "$php")" \
        "$(json_str_or_null "$node_spec")" "$build" "$(json_str "${docroot:-.}")" "$(json_str_or_null "$db")" \
        "$(json_str_or_null "$branch")"
    printf ',"sha":%s,"committed_at":%s,"subject":%s,"repo":%s,"preview":%s,"last_event":%s' \
        "$(json_str_or_null "$full_sha")" "$(json_str_or_null "$committed_at")" "$(json_str_or_null "$subject")" \
        "$(json_str_or_null "$repo")" "$preview_json" "$last_event"
    local last_db_backup=null last_up_backup=null
    if [[ -s "$f" ]]; then
        last_db_backup="$(grep -E '"kind":"backup-database","phase":"(succeeded|failed)"' "$f" | tail -n 1 || true)"
        last_up_backup="$(grep -E '"kind":"backup-uploads","phase":"(succeeded|failed)"' "$f" | tail -n 1 || true)"
        [[ -n "$last_db_backup" ]] || last_db_backup=null
        [[ -n "$last_up_backup" ]] || last_up_backup=null
    fi
    printf ',"last_run":%s,"last_deploy":%s,"deployed_at":%s' "$last_run" "$last_deploy" "$(json_str_or_null "$deployed_at")"
    printf ',"last_backups":{"database":%s,"uploads":%s}}\n' "$last_db_backup" "$last_up_backup"
}

api_sites() {
    [[ $# -eq 0 ]] || api_die bad_request "sites takes no arguments"
    local -a names=()
    mapfile -t names < <(provisioned_site_names)
    api_header
    printf ',"base_domain":%s,"sites":' "$(json_str "$BASE_DOMAIN")"
    parallel_map api_site_summary "${names[@]}" | json_lines_to_array
    printf '}\n'
}

# $1 a validated, existing site name — exits not_found otherwise.
api_require_site() {
    local name="$1"
    [[ -n "$name" ]] || api_die bad_request "site name required"
    api_valid validate_name "$name"
    is_provisioned "$name" || api_die not_found "'$name' is not provisioned"
}

# The resolved config of site $1, as one JSON object. Run in a subshell
# by the caller: parse_config can die on a malformed config.
api_site_config() {
    local name="$1" cfg_path=""
    if is_preview "$name"; then
        read_preview_meta "$name" || die "preview metadata unreadable"
        resolve_preview_config "$name" "$PREVIEW_PROJECT" "$PREVIEW_MODE" >/dev/null
    else
        cfg_path="$(resolve_config_path "$name")"
        [[ -n "$cfg_path" ]] || die "no config found (.ddev/config.yaml or sidecar)"
        parse_config "$name" "$cfg_path" 0 >/dev/null
    fi
    local -a hostnames=() h
    hostnames+=("$name.$BASE_DOMAIN")
    for h in "${ADDITIONAL_HOSTNAMES[@]}"; do hostnames+=("$h.$BASE_DOMAIN"); done
    local basic_auth="${BASIC_AUTH_CONFIG:-}"
    if [[ -z "$basic_auth" ]]; then
        if is_preview "$name"; then basic_auth=true; else basic_auth="$BASIC_AUTH_DEFAULT"; fi
    fi
    local config_source=sidecar
    [[ "$cfg_path" == */.ddev/config.yaml ]] && config_source=ddev
    is_preview "$name" && config_source=preview
    [[ -f "$(ext_config_path "$name")" ]] && config_source+="+ddeploy"

    printf '{"source":%s,"php":%s,"docroot":%s,"db_name":%s,"hostnames":%s,"custom_domains":%s' \
        "$(json_str "$config_source")" "$(json_str_or_null "${PHP_VERSION:-}")" "$(json_str "${DOCROOT:-.}")" \
        "$(json_str_or_null "${DB_NAME:-}")" "$(json_str_array "${hostnames[@]}")" \
        "$(json_str_array "${ADDITIONAL_FQDNS[@]}")"
    printf ',"upload_dirs":%s,"persistent_files":%s,"basic_auth":%s' \
        "$(json_str_array "${UPLOAD_DIRS[@]}")" "$(json_str_array "${PERSISTENT_FILES[@]}")" "$(json_bool "$basic_auth")"
    printf ',"node":{"spec":%s,"source":%s},"build":%s' \
        "$(json_str_or_null "${NODE_VERSION_SPEC:-}")" "$(json_str_or_null "${NODE_VERSION_SOURCE:-}")" \
        "$(json_bool "${BUILD_ENABLED:-false}")"
    printf ',"queue_workers":%s,"schedule":%s' \
        "$(json_str_array "${QUEUE_WORKERS[@]}")" "$(json_str_array "${SCHEDULE[@]}")"
    local -a extra_hosts=() pb=()
    extra_hosts=("${ADDITIONAL_HOSTNAMES[@]}")
    mapfile -t pb < <(read_preview_branch_patterns "$name" 2>/dev/null)
    # Effective values of everything `api settings` can override, as the
    # next deploy would apply them (server-wide defaults filled in).
    printf ',"settings":{"basic_auth":%s,"client_max_body_size":%s,"fpm_max_children":%s,"security_headers":%s' \
        "$(json_str "$basic_auth")" "$(json_str "${CLIENT_MAX_BODY_SIZE_CONFIG:-$CLIENT_MAX_BODY_SIZE}")" \
        "$(json_str "${FPM_MAX_CHILDREN_CONFIG:-$FPM_MAX_CHILDREN}")" "$(json_str "${SECURITY_HEADERS:-true}")"
    printf ',"static_cache":%s,"deny_php_in_uploads":%s,"db_backup_retention_days":%s,"nodejs_version":%s,"build":%s,"composer_dev":%s' \
        "$(json_str "${STATIC_CACHE:-}")" "$(json_str "${DENY_PHP_IN_UPLOADS:-true}")" \
        "$(json_str "${DB_BACKUP_RETENTION_DAYS_CONFIG:-$DB_BACKUP_RETENTION_DAYS}")" "$(json_str "${NODE_VERSION_SPEC:-}")" \
        "$(json_str "${BUILD_ENABLED:-false}")" "$(json_str "${COMPOSER_DEV:-false}")"
    printf ',"additional_hostnames":%s,"additional_fqdns":%s,"auth_exempt_paths":%s,"deny_php_paths":%s,"backup_exclude":%s,"preview_branches":%s}}' \
        "$(json_str_array "${extra_hosts[@]}")" "$(json_str_array "${ADDITIONAL_FQDNS[@]}")" \
        "$(json_str_array "${AUTH_EXEMPT_PATHS[@]}")" "$(json_str_array "${DENY_PHP_PATHS[@]}")" \
        "$(json_str_array "${BACKUP_EXCLUDE[@]}")" "$(json_str_array "${pb[@]}")"
}

api_site() {
    local name="${1:-}"
    [[ $# -le 1 ]] || api_die bad_request "site takes one site name"
    api_require_site "$name"

    local config config_error="" errf
    errf="$(mktemp)"
    if ! config="$(api_site_config "$name" 2>"$errf")"; then
        config=null
        config_error="$(grep -E '^\[error\]' "$errf" | tail -n 1 | sed 's/^\[error\] *//' || true)"
        [[ -n "$config_error" ]] || config_error="$(tail -n 1 "$errf")"
    fi
    rm -f "$errf"

    local overrides=null f
    f="$(override_config_path "$name")"
    [[ -s "$f" ]] && overrides="$(yq -o=json -I=0 '.' "$f" 2>/dev/null || echo null)"

    local -a release_objs=()
    local rels current d
    rels="$(site_root "$name")/releases"
    current="$(current_release_real "$name")"
    if [[ -d "$rels" ]]; then
        for d in "$rels"/*/; do
            d="${d%/}"
            [[ -d "$d" ]] || continue
            [[ "$(basename "$d")" == .* ]] && continue
            local rsha
            rsha="$(git -c safe.directory='*' -C "$d" rev-parse HEAD 2>/dev/null || true)"
            local is_current=false
            [[ "$d" == "$current" ]] && is_current=true
            release_objs+=("{\"id\":$(json_str "$(basename "$d")"),\"sha\":$(json_str_or_null "$rsha"),\"current\":$is_current}")
        done
    fi

    local -a legacy=()
    f="$(deploy_history_path "$name")"
    if [[ -s "$f" ]]; then
        local ts lsha
        while IFS=$'\t' read -r ts lsha; do
            [[ -n "$lsha" ]] && legacy+=("{\"ts\":$(json_str "$ts"),\"sha\":$(json_str "$lsha")}")
        done < <(tail -n 100 "$f")
    fi

    local -a previews=()
    local pf
    for pf in "$GENERATED_DIR"/*.preview; do
        [[ -f "$pf" ]] || continue
        grep -qxF "PROJECT=$name" "$pf" && previews+=("$(basename "$pf" .preview)")
    done

    api_header
    printf ',"site":'
    api_site_summary "$name" | tr -d '\n'
    printf ',"config":%s,"config_error":%s,"overrides":%s,"deploy_branch":%s' \
        "$config" "$(json_str_or_null "$config_error")" "$overrides" \
        "$(json_str_or_null "$(read_deploy_branch "$name" 2>/dev/null || true)")"
    printf ',"releases":'
    printf '%s\n' "${release_objs[@]}" | json_lines_to_array
    printf ',"legacy_deploys":'
    printf '%s\n' "${legacy[@]}" | json_lines_to_array
    printf ',"previews":%s}\n' "$(json_str_array "${previews[@]}")"
}

# --- events -------------------------------------------------------------

api_events() {
    local site="" project="" run="" limit=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --site) site="${2:-}"; shift ;;
            --project) project="${2:-}"; shift ;;
            --run) run="${2:-}"; shift ;;
            --limit) limit="${2:-}"; shift ;;
            *) api_die bad_request "events: unknown option '$1'" ;;
        esac
        shift
    done
    [[ -z "$site" ]] || api_valid validate_name "$site"
    [[ -z "$project" ]] || api_valid validate_name "$project"
    [[ -z "$run" ]] || api_valid validate_run_id "$run"
    limit="$(api_int "$limit" 200 5000 --limit)"

    local -a files=()
    if [[ -n "$site" ]]; then
        [[ -f "$EVENTS_DIR/$site.jsonl" ]] && files=("$EVENTS_DIR/$site.jsonl")
    else
        local f
        for f in "$EVENTS_DIR"/*.jsonl; do [[ -f "$f" ]] && files+=("$f"); done
    fi

    api_header
    printf ',"events":'
    if [[ "${#files[@]}" -eq 0 ]]; then
        printf '[]'
    else
        # Every line starts with {"ts":"<ISO-8601 UTC>", so sorting on that
        # first field is chronological; stable (-s), so events from the
        # same second keep the order they were appended in. The filters match this tool's own
        # serialization of already-validated values, so fixed strings are
        # exact.
        # Each file is append-ordered, so its newest $limit matches are its
        # last ones: only those get merged, whatever the files' total size.
        local f
        for f in "${files[@]}"; do
            { if [[ -n "$project" ]]; then grep -F "\"project\":\"$project\"" "$f" || true; else cat "$f"; fi; } \
                | { if [[ -n "$run" ]]; then grep -F "\"run_id\":\"$run\"" || true; else cat; fi; } \
                | tail -n "$limit"
        done | { grep '^{"ts":' || true; } | sort -s -t, -k1,1 | tail -n "$limit" | json_lines_to_array
    fi
    printf '}\n'
}

# --- previews -----------------------------------------------------------

api_previews() {
    local project="${1:-}"
    [[ $# -le 1 ]] || api_die bad_request "previews takes one project name"
    [[ -n "$project" ]] || api_die bad_request "project name required"
    api_valid validate_name "$project"

    local -a objs=()
    local pf name
    for pf in "$GENERATED_DIR"/*.preview; do
        [[ -f "$pf" ]] || continue
        grep -qxF "PROJECT=$project" "$pf" || continue
        name="$(basename "$pf" .preview)"
        read_preview_meta "$name" || continue
        local dir sha="" committed_at="" subject="" deployed=""
        dir="$(site_dir "$name")"
        if [[ -d "$dir/.git" ]]; then
            local last
            last="$(git -c safe.directory='*' -C "$dir" log -1 --format='%H%x1f%cI%x1f%s' 2>/dev/null || true)"
            [[ -n "$last" ]] && IFS=$'\x1f' read -r sha committed_at subject <<< "$last"
        fi
        deployed="$(cat "$(preview_deployed_path "$name")" 2>/dev/null || true)"
        objs+=("{\"name\":$(json_str "$name"),\"url\":$(json_str "https://$name.$BASE_DOMAIN"),\"branch\":$(json_str "$PREVIEW_BRANCH"),\"mode\":$(json_str "$PREVIEW_MODE"),\"provisioned\":$(is_provisioned "$name" && echo true || echo false),\"sha\":$(json_str_or_null "$sha"),\"committed_at\":$(json_str_or_null "$committed_at"),\"subject\":$(json_str_or_null "$subject"),\"deployed_sha\":$(json_str_or_null "$deployed")}")
    done
    api_header
    printf ',"project":%s,"previews":' "$(json_str "$project")"
    printf '%s\n' "${objs[@]}" | json_lines_to_array
    printf '}\n'
}

# --- doctor -------------------------------------------------------------

# doctor_result TSV rows on stdin -> JSON array.
api_doctor_rows() {
    local status check detail first=1
    printf '['
    while IFS=$'\t' read -r status check detail; do
        [[ -n "$status" ]] || continue
        [[ "$first" -eq 1 ]] || printf ','
        first=0
        printf '{"status":%s,"check":%s,"detail":%s}' "$(json_str "$status")" "$(json_str "$check")" "$(json_str "$detail")"
    done
    printf ']'
}

api_doctor_site() {
    local name="$1" block
    block="$(doctor_check_site "$name" 2>/dev/null)" || block+=$'\n'"fail"$'\t'"check"$'\t'"crashed unexpectedly"
    local preview=null
    if is_preview "$name" && read_preview_meta "$name" 2>/dev/null; then
        preview="{\"project\":$(json_str "$PREVIEW_PROJECT"),\"mode\":$(json_str "$PREVIEW_MODE")}"
    fi
    printf '{"name":%s,"worst":%s,"preview":%s,"checks":%s}\n' "$(json_str "$name")" \
        "$(json_str "$(doctor_worst "$block")")" "$preview" "$(api_doctor_rows <<< "$block")"
}

api_doctor() {
    local only="${1:-}"
    [[ $# -le 1 ]] || api_die bad_request "doctor takes at most one site name"
    [[ -z "$only" ]] || api_require_site "$only"
    local -a names=()
    if [[ -n "$only" ]]; then
        names=("$only")
    else
        mapfile -t names < <(provisioned_site_names)
    fi
    local infra
    infra="$(doctor_check_infra 2>/dev/null)" || infra+=$'\n'"fail"$'\t'"infra"$'\t'"infra checks crashed unexpectedly"
    api_header
    printf ',"checked_at":%s' "$(json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    printf ',"server":{"worst":%s,"checks":%s}' "$(json_str "$(doctor_worst "$infra")")" "$(api_doctor_rows <<< "$infra")"
    printf ',"sites":'
    parallel_map api_doctor_site "${names[@]}" | json_lines_to_array
    printf '}\n'
}

# --- logs ---------------------------------------------------------------

# Reads file $1 as {size, offset, next_offset, rotated, text}: from byte
# $2 on (offset mode) or its last $3 lines (when $2 is empty). Capped at
# API_MAX_READ_BYTES per call; the caller pages on with next_offset.
api_read_file() {
    local file="$1" offset="$2" lines="$3"
    local size tmp rotated=false start
    size="$(stat -c %s "$file" 2>/dev/null || wc -c < "$file")"
    size="${size//[[:space:]]/}"
    tmp="$(mktemp)"
    if [[ -n "$offset" ]]; then
        if (( offset > size )); then
            offset=0
            rotated=true
        fi
        tail -c +"$((offset + 1))" "$file" 2>/dev/null | head -c "$((size - offset))" | head -c "$API_MAX_READ_BYTES" > "$tmp" || true
        start="$offset"
    else
        # The last lines of (at most) the last API_MAX_READ_BYTES bytes, up
        # to the size measured above — so next_offset can't skip anything
        # appended in between. tail -c +N seeks: a multi-GB access log
        # costs no more than a small one.
        local from=$(( size > API_MAX_READ_BYTES ? size - API_MAX_READ_BYTES : 0 ))
        tail -c +"$((from + 1))" "$file" 2>/dev/null | head -c "$((size - from))" | tail -n "$lines" > "$tmp" || true
        start=$(( size - $(wc -c < "$tmp") ))
    fi
    local got; got="$(wc -c < "$tmp")"
    got="${got//[[:space:]]/}"
    printf ',"size":%s,"offset":%s,"next_offset":%s,"rotated":%s,"text":' "$size" "$start" "$((start + got))" "$rotated"
    json_str_file "$tmp"
    rm -f "$tmp"
}

# Parses --lines/--offset into API_READ_OFFSET / API_READ_LINES.
api_parse_read_opts() {
    API_READ_OFFSET="" API_READ_LINES=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --lines|-n) API_READ_LINES="${2:-}"; shift ;;
            --offset) API_READ_OFFSET="${2:-}"; shift ;;
            *) api_die bad_request "unknown option '$1'" ;;
        esac
        shift
    done
    [[ -z "$API_READ_OFFSET" || -z "$API_READ_LINES" ]] || api_die bad_request "--lines and --offset are mutually exclusive"
    [[ -z "$API_READ_OFFSET" ]] || API_READ_OFFSET="$(api_int "$API_READ_OFFSET" 0 999999999999 --offset)"
    API_READ_LINES="$(api_int "$API_READ_LINES" 200 5000 --lines)"
    [[ "$API_READ_LINES" -gt 0 ]] || API_READ_LINES=200
}

# Log names the api reads, each mapped to one fixed path — never a path
# built from free text:
#   <site>                $LOG_DIR/<site>.log   ddeploy's own (deploys, previews...)
#   webhook, backup-*...  $LOG_DIR/<name>.log   fleet logs (same charset as a site)
#   <site>.access|error   /var/log/nginx/<site>.access|error.log   per-site nginx (+ PHP errors)
#   nginx_access|error    /var/log/nginx/access|error.log          server-wide nginx
#   phpX.Y_fpm            /var/log/phpX.Y-fpm.log                  PHP-FPM master (pool warnings)
# '.' and '_' never appear in a site name, so none of these can collide.
API_LOG_NAME_RE='^([a-z0-9][a-z0-9-]{0,27}(\.(access|error))?|nginx_(access|error)|php[0-9]\.[0-9]{1,2}_fpm)$'

api_log_path() {
    local name="$1"
    [[ "$name" =~ $API_LOG_NAME_RE ]] || die "invalid log name '$name'"
    case "$name" in
        nginx_access) echo /var/log/nginx/access.log ;;
        nginx_error)  echo /var/log/nginx/error.log ;;
        php*_fpm)     echo "/var/log/${name%_fpm}-fpm.log" ;;
        *.access|*.error) echo "/var/log/nginx/$name.log" ;;
        *)            echo "$LOG_DIR/$name.log" ;;
    esac
}

# One {"name","kind","site","label","size","modified_at"} object for log
# file $2 named $1.
api_log_entry() {
    local name="$1" file="$2" kind="$3" site="$4" label="$5"
    printf '{"name":%s,"kind":%s,"site":%s,"label":%s,"size":%s,"modified_at":%s}' \
        "$(json_str "$name")" "$(json_str "$kind")" "$(json_str_or_null "$site")" "$(json_str "$label")" \
        "$(json_num "$(stat -c %s "$file")")" "$(json_str "$(date -u -d "@$(stat -c %Y "$file")" +%Y-%m-%dT%H:%M:%SZ)")"
}

api_logs() {
    if [[ $# -eq 0 ]]; then
        local -a objs=()
        local f name kind
        for f in "$LOG_DIR"/*.log; do
            [[ -f "$f" ]] || continue
            name="$(basename "$f" .log)"
            [[ "$name" =~ $NAME_RE ]] || continue
            case "$name" in
                webhook|webhook-other) kind=webhook ;;
                backup-uploads|backup-database|prune-previews|server-config) kind=fleet ;;
                *) kind=site ;;
            esac
            local site="" label="ddeploy"
            if [[ "$kind" == site ]]; then site="$name"; label="ddeploy (deploys, previews)"; fi
            objs+=("$(api_log_entry "$name" "$f" "$kind" "$site" "$label")")
        done
        local site_name
        while IFS= read -r site_name; do
            [[ -f "/var/log/nginx/$site_name.error.log" ]] && objs+=("$(api_log_entry "$site_name.error" "/var/log/nginx/$site_name.error.log" nginx "$site_name" "nginx errors + PHP")")
            [[ -f "/var/log/nginx/$site_name.access.log" ]] && objs+=("$(api_log_entry "$site_name.access" "/var/log/nginx/$site_name.access.log" nginx "$site_name" "nginx access")")
        done < <(provisioned_site_names)
        [[ -f /var/log/nginx/error.log ]] && objs+=("$(api_log_entry nginx_error /var/log/nginx/error.log server "" "nginx errors (all sites)")")
        [[ -f /var/log/nginx/access.log ]] && objs+=("$(api_log_entry nginx_access /var/log/nginx/access.log server "" "nginx access (all sites)")")
        for f in /var/log/php*-fpm.log; do
            [[ -f "$f" ]] || continue
            name="$(basename "$f" -fpm.log)_fpm"
            [[ "$name" =~ $API_LOG_NAME_RE ]] && objs+=("$(api_log_entry "$name" "$f" server "" "PHP-FPM ${name%_fpm}")")
        done
        api_header
        printf ',"logs":'
        printf '%s\n' "${objs[@]}" | json_lines_to_array
        printf '}\n'
        return 0
    fi
    local name="$1"; shift
    local file
    file="$( (api_log_path "$name") 2>/dev/null )" || api_die bad_request "invalid log name '$name'"
    api_parse_read_opts "$@"
    [[ -f "$file" ]] || api_die not_found "no log named '$name'"
    api_header
    printf ',"name":%s' "$(json_str "$name")"
    api_read_file "$file" "$API_READ_OFFSET" "$API_READ_LINES"
    printf '}\n'
}

# --- inspect-repo -------------------------------------------------------

api_valid_repo_url() {
    local url="$1"
    [[ -n "$url" ]] || die "repo URL required"
    [[ "$url" =~ $API_REPO_URL_RE ]] || die "repo URL '$url' must be ssh://, git@ or https://, with no spaces or shell characters"
    # A host that starts with '-' is how a URL becomes an ssh option
    # (CVE-2017-1000117); git refuses these itself nowadays, so does this.
    [[ "$url" != *://-* && "$url" != git@-* && "$url" != *@-* ]] || die "repo URL '$url' has a host starting with '-'"
}

# What `provision` would find in repo $1 (branch $2 or its default):
# whether the deploy key can reach it, its branches, and the config/CMS
# detection that decides which provision fields are still needed. Clones
# shallowly into a temp dir and only reads files — nothing from the repo
# is executed.
api_inspect_repo() {
    local url="" branch=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --branch) branch="${2:-}"; shift ;;
            -*) api_die bad_request "inspect-repo: unknown option '$1'" ;;
            *) [[ -z "$url" ]] || api_die bad_request "inspect-repo takes one URL"; url="$1" ;;
        esac
        shift
    done
    api_valid api_valid_repo_url "$url"
    api_valid validate_branch_name "$branch" "--branch"

    local ssh_cmd; ssh_cmd="$(git_ssh_command)"
    local refs errf
    errf="$(mktemp)"
    if ! refs="$(GIT_SSH_COMMAND="$ssh_cmd" GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote --symref "$url" HEAD 'refs/heads/*' 2>"$errf")"; then
        local err; err="$(grep -v '^$' "$errf" | tail -n 2 | tr '\n' ' ' || true)"
        rm -f "$errf"
        api_header
        printf ',"url":%s,"reachable":false,"error":%s}\n' "$(json_str "$url")" "$(json_str "${err:-git ls-remote failed}")"
        return 0
    fi
    rm -f "$errf"

    local default_branch="" line
    local -a branches=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^ref:\ refs/heads/([^[:space:]]+)[[:space:]]+HEAD$ ]]; then
            default_branch="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[0-9a-f]{40}[[:space:]]+refs/heads/(.+)$ ]]; then
            branches+=("${BASH_REMATCH[1]}")
        fi
    done <<< "$refs"
    local target="${branch:-$default_branch}"

    api_header
    printf ',"url":%s,"reachable":true,"default_branch":%s,"branches":%s,"branch":%s' \
        "$(json_str "$url")" "$(json_str_or_null "$default_branch")" \
        "$(json_str_array "${branches[@]}")" "$(json_str_or_null "$target")"

    local found=false b
    for b in "${branches[@]}"; do [[ "$b" == "$target" ]] && found=true; done
    if [[ -z "$target" || "$found" != true ]]; then
        printf ',"error":%s,"detected":null}\n' "$(json_str "branch '${target}' not found in the repository")"
        return 0
    fi

    local tmp; tmp="$(mktemp -d)"
    # shellcheck disable=SC2064  # $tmp is ours (mktemp), expand it now.
    trap "rm -rf '$tmp'" EXIT
    if ! GIT_SSH_COMMAND="$ssh_cmd" GIT_TERMINAL_PROMPT=0 timeout 120 \
        git clone --quiet --depth 1 --single-branch --no-tags --branch "$target" -- "$url" "$tmp/repo" >/dev/null 2>&1; then
        printf ',"error":%s,"detected":null}\n' "$(json_str "shallow clone of '$target' failed")"
        return 0
    fi
    local repo="$tmp/repo" ddev="$tmp/repo/.ddev/config.yaml" ddev_json=null
    if [[ -f "$ddev" ]]; then
        local dname dphp ddoc dnode
        dname="$(yq eval '.name // ""' "$ddev" 2>/dev/null || true)"
        dphp="$(yq eval '.php_version // ""' "$ddev" 2>/dev/null || true)"
        ddoc="$(yq eval '.docroot // ""' "$ddev" 2>/dev/null || true)"
        dnode="$(yq eval '.nodejs_version // ""' "$ddev" 2>/dev/null || true)"
        ddev_json="{\"name\":$(json_str_or_null "$dname"),\"php_version\":$(json_str_or_null "${dphp//\"/}"),\"docroot\":$(json_str_or_null "$ddoc"),\"nodejs_version\":$(json_str_or_null "${dnode//\"/}")}"
    fi
    local cms; cms="$(detect_cms "$repo")"
    cms_defaults "$cms"
    local nvmrc=""
    [[ -f "$repo/.nvmrc" ]] && nvmrc="$(head -n 1 "$repo/.nvmrc" | tr -d '[:space:]' | cut -c1-20)"
    printf ',"detected":{"ddev":%s,"ddeploy_config":%s,"cms":%s,"cms_docroot":%s,"package_json":%s,"nvmrc":%s,"composer_json":%s}' \
        "$ddev_json" "$([[ -f "$repo/.ddeploy/config.yaml" ]] && echo true || echo false)" \
        "$(json_str_or_null "$cms")" "$(json_str_or_null "$CMS_DOCROOT")" \
        "$([[ -f "$repo/package.json" ]] && echo true || echo false)" "$(json_str_or_null "$nvmrc")" \
        "$([[ -f "$repo/composer.json" ]] && echo true || echo false)"
    # No .ddev/config.yaml: provision --non-interactive needs --php.
    printf ',"requires":{"php":%s}}\n' "$([[ -f "$ddev" ]] && echo false || echo true)"
}

# --- runs ---------------------------------------------------------------

api_run() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        start) api_run_start "$@" ;;
        show)  api_run_show "$@" ;;
        log)   api_run_log "$@" ;;
        cancel) api_run_cancel "$@" ;;
        *) api_die bad_request "run: expected start, show, log or cancel" ;;
    esac
}

api_valid_actor() {
    [[ "$1" =~ $API_ACTOR_RE ]] || die "--actor must be an email address"
}

# Space-separated list $1, each entry checked with validator $2 (label $3).
api_valid_each() {
    local list="$1" fn="$2" label="$3" v
    [[ "$list" != *$'\n'* ]] || die "$label contains a newline"
    for v in $list; do "$fn" "$v" "$label entry"; done
}

api_valid_upload_dir() {
    local val="$1" label="$2"
    [[ "$val" =~ ^[A-Za-z0-9._/-]+$ && "$val" != /* ]] || die "$label ('$val') must be a relative path"
}

api_run_start() {
    local kind="${1:-}"
    shift || true
    local actor="" name="" url=""
    local -a argv=() flags=()
    case "$kind" in
        deploy|provision|rollback|db-import|db-restore|db-snapshot|preview-create|preview-deploy|preview-remove|uploads-import|uploads-fetch|uploads-restore|uploads-snapshot|backup-database|backup-uploads|backup-restore-db|backup-restore-uploads) ;;
        *) api_die bad_request "run start: unknown kind '$kind'" ;;
    esac
    local preview=0
    [[ "$kind" == preview-* ]] && preview=1
    local sha="" snapshot="" upload_dir="" upload_mode=merge backup_file="" backup_version="" fetch_source="" fetch_port=22

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --actor) actor="${2:-}"; shift ;;
            --sha)
                [[ "$kind" == rollback ]] || api_die bad_request "--sha is only for rollback"
                [[ "${2:-}" =~ ^[0-9a-f]{7,40}$ ]] || api_die bad_request "--sha must be a commit SHA"
                sha="$2"; shift ;;
            --snapshot)
                if [[ "$kind" == db-restore ]]; then api_valid validate_snapshot_id "${2:-}"
                elif [[ "$kind" == uploads-restore ]]; then api_valid validate_uploads_snapshot_id "${2:-}"
                else api_die bad_request "--snapshot is only for db-restore and uploads-restore"
                fi
                snapshot="$2"; shift ;;
            --file)
                [[ "$kind" == backup-restore-db ]] || api_die bad_request "--file is only for backup-restore-db"
                api_valid validate_backup_dump_name "${2:-}"
                backup_file="$2"; shift ;;
            --version)
                [[ "$kind" == backup-restore-uploads ]] || api_die bad_request "--version is only for backup-restore-uploads"
                [[ "${2:-}" =~ $UPLOADS_VERSION_ID_RE ]] || api_die bad_request "invalid backup version '${2:-}'"
                backup_version="$2"; shift ;;
            --source)
                [[ "$kind" == uploads-fetch ]] || api_die bad_request "--source is only for uploads-fetch"
                fetch_source="${2:-}"; shift ;;
            --port)
                [[ "$kind" == uploads-fetch ]] || api_die bad_request "--port is only for uploads-fetch"
                fetch_port="${2:-}"; shift ;;
            --dir)
                [[ "$kind" == uploads-import || "$kind" == uploads-fetch || "$kind" == backup-restore-uploads ]] || api_die bad_request "--dir is only for uploads-import, uploads-fetch and backup-restore-uploads"
                [[ "${2:-}" =~ ^[A-Za-z0-9._/-]{1,200}$ && "${2:-}" != /* ]] || api_die bad_request "--dir must be one of the site's upload dirs"
                upload_dir="$2"; shift ;;
            --mode)
                [[ "$kind" == uploads-import || "$kind" == uploads-fetch ]] || api_die bad_request "--mode is only for uploads-import and uploads-fetch"
                [[ "${2:-}" == merge || "${2:-}" == replace ]] || api_die bad_request "--mode is merge or replace"
                upload_mode="$2"; shift ;;
            --shared|--isolated|--seed|--no-seed)
                [[ "$kind" == preview-create ]] || api_die bad_request "$1 is only for preview-create"
                flags+=("$1") ;;
            --branch)
                [[ "$kind" == provision || "$preview" -eq 1 ]] || api_die bad_request "--branch is only for provision and previews"
                api_valid validate_branch_name "${2:-}" "--branch"
                [[ -n "${2:-}" ]] && flags+=(--branch "$2")
                shift ;;
            --php)
                [[ "$kind" == provision ]] || api_die bad_request "--php is only for provision"
                api_valid validate_php_version "${2:-}" "--php"
                flags+=(--php "$2"); shift ;;
            --docroot)
                [[ "$kind" == provision ]] || api_die bad_request "--docroot is only for provision"
                api_valid validate_relative_path "${2:-}" "--docroot"
                [[ -n "${2:-}" ]] && flags+=(--docroot "$2")
                shift ;;
            --db)
                [[ "$kind" == provision ]] || api_die bad_request "--db is only for provision"
                api_valid validate_db_identifier "${2:-}" "--db"
                flags+=(--db "$2"); shift ;;
            --hostnames|--custom-domains)
                [[ "$kind" == provision ]] || api_die bad_request "$1 is only for provision"
                api_valid api_valid_each "${2:-}" validate_hostname "$1"
                [[ -n "${2// /}" ]] && flags+=("$1" "$2")
                shift ;;
            --upload-dirs)
                [[ "$kind" == provision ]] || api_die bad_request "--upload-dirs is only for provision"
                api_valid api_valid_each "${2:-}" api_valid_upload_dir "--upload-dirs"
                [[ -n "${2// /}" ]] && flags+=(--upload-dirs "$2")
                shift ;;
            --node)
                [[ "$kind" == provision ]] || api_die bad_request "--node is only for provision"
                local node="${2:-}"
                [[ "$node" == lts ]] && node="lts/*"
                api_valid validate_node_version_spec "$node" "--node"
                flags+=(--node "$node"); shift ;;
            --auth|--no-auth)
                [[ "$kind" == provision || "$kind" == preview-create ]] || api_die bad_request "$1 is only for provision and preview-create"
                flags+=("$1") ;;
            --build|--no-build)
                [[ "$kind" == provision ]] || api_die bad_request "$1 is only for provision"
                flags+=("$1") ;;
            -*) api_die bad_request "run start: option '$1' is not allowed" ;;
            *)
                if [[ -z "$name" ]]; then name="$1"
                elif [[ "$kind" == provision && -z "$url" ]]; then url="$1"
                else api_die bad_request "run start: unexpected argument '$1'"
                fi ;;
        esac
        shift
    done
    api_valid api_valid_actor "$actor"
    [[ -n "$name" ]] || api_die bad_request "site name required"
    api_valid validate_name "$name"

    local id; id="$(new_run_id)"
    if [[ "$kind" != provision ]]; then
        is_provisioned "$name" || api_die not_found "'$name' is not provisioned"
    fi
    # Previews: $name is the project; the run is about the preview site
    # <project>-<branch> (preview_slug), which is what gets locked, logged
    # and recorded.
    local run_site="$name"
    if [[ "$preview" -eq 1 ]]; then
        is_preview "$name" && api_die bad_request "'$name' is itself a preview — previews belong to a project"
        local branch="" i
        for (( i = 0; i < ${#flags[@]}; i++ )); do
            [[ "${flags[i]}" == --branch ]] && branch="${flags[i+1]}"
        done
        [[ -n "$branch" ]] || api_die bad_request "--branch <branch> required"
        run_site="$( (preview_slug "$name" "$branch") 2>/dev/null )" || api_die bad_request "can't derive a preview name from '$name' + '$branch'"
        [[ "$run_site" =~ $NAME_RE ]] || api_die bad_request "can't derive a preview name from '$name' + '$branch'"
        local owner=""
        if is_preview "$run_site" && read_preview_meta "$run_site"; then owner="$PREVIEW_PROJECT"; fi
        if [[ "$kind" == preview-create ]]; then
            [[ -z "$owner" ]] || api_die conflict "a preview of '$branch' already exists ($run_site) — redeploy it instead"
            is_provisioned "$run_site" && api_die conflict "'$run_site' already exists and isn't a preview of '$name'"
            local remote
            remote="$(GIT_SSH_COMMAND="$(git_ssh_command)" timeout 30 git -c safe.directory='*' -C "$(site_dir "$name")" ls-remote origin "refs/heads/$branch" 2>/dev/null || true)"
            [[ -n "$remote" ]] || api_die bad_request "branch '$branch' doesn't exist on the remote"
        else
            [[ "$owner" == "$name" ]] || api_die not_found "no preview of '$branch' for '$name'"
        fi
    fi
    if [[ "$kind" == deploy || "$kind" == rollback ]]; then
        is_preview "$name" && api_die bad_request "'$name' is a preview — previews are deployed with deploy-preview"
    fi
    if [[ "$kind" == deploy ]]; then
        argv=(deploy "$name")
    elif [[ "$kind" == rollback ]]; then
        argv=(deploy "$name" --rollback ${sha:+"$sha"})
    elif [[ "$kind" == db-snapshot ]]; then
        argv=(db-snapshot "$name" --reason manual)
    elif [[ "$kind" == db-restore ]]; then
        [[ -n "$snapshot" ]] || api_die bad_request "--snapshot <id> required"
        argv=(db-import "$name" --snapshot "$snapshot" --yes)
    elif [[ "$kind" == preview-create ]]; then
        local -a pflags=()
        for (( i = 0; i < ${#flags[@]}; i++ )); do
            case "${flags[i]}" in
                --branch) i=$((i + 1)) ;;
                *) pflags+=("${flags[i]}") ;;
            esac
        done
        argv=(provision-preview "$name" "$branch" "${pflags[@]}")
    elif [[ "$kind" == preview-deploy ]]; then
        argv=(deploy-preview "$name" "$branch")
    elif [[ "$kind" == preview-remove ]]; then
        # --purge-db only ever drops an isolated preview's own database;
        # a shared one's belongs to the project (remove-preview -h).
        argv=(remove-preview "$name" "$branch" --purge-db --purge-files)
    elif [[ "$kind" == uploads-import ]]; then
        [[ -n "$upload_dir" ]] || api_die bad_request "--dir <upload dir> required"
        # The dir must be one the site actually declares — checked before
        # reading a possibly huge upload.
        ( uploads_resolve_site "$name" >/dev/null 2>&1 && uploads_require_dir "$upload_dir" >/dev/null 2>&1 ) \
            || api_die bad_request "'$upload_dir' isn't one of '$name's upload dirs"
        local spool
        spool="$(api_spool_upload "$id")"
        argv=(uploads-import "$name" --dir "$upload_dir" --from-file "$spool" --mode "$upload_mode" --yes --delete-file)
    elif [[ "$kind" == uploads-fetch ]]; then
        [[ -n "$upload_dir" ]] || api_die bad_request "--dir <upload dir> required"
        ( uploads_resolve_site "$name" >/dev/null 2>&1 && uploads_require_dir "$upload_dir" >/dev/null 2>&1 ) \
            || api_die bad_request "'$upload_dir' isn't one of '$name's upload dirs"
        api_valid fetch_parse_source "$fetch_source" "$fetch_port"
        fetch_parse_source "$fetch_source" "$fetch_port"
        # Started only for a host whose key was confirmed (fetch-test --accept).
        local scan hstatus; scan="$(mktemp)"
        hstatus="$(fetch_host_status "$FETCH_SRC_HOST" "$fetch_port" "$scan")"
        rm -f "$scan"
        [[ "$hstatus" == known ]] || api_die conflict "$FETCH_SRC_HOST's host key isn't confirmed ($hstatus) — test the connection first"
        argv=(uploads-import "$name" --dir "$upload_dir" --from-ssh "$fetch_source" --ssh-port "$fetch_port" --mode "$upload_mode" --yes)
    elif [[ "$kind" == backup-database || "$kind" == backup-uploads || "$kind" == backup-restore-db || "$kind" == backup-restore-uploads ]]; then
        api_backups_require_target "$name" "$kind"
        case "$kind" in
            backup-database) argv=(backup-database "$name") ;;
            backup-uploads) argv=(backup-uploads "$name") ;;
            backup-restore-db)
                [[ -n "$backup_file" ]] || api_die bad_request "--file <dump> required"
                argv=(db-import "$name" --from-backup "$backup_file" --yes) ;;
            backup-restore-uploads)
                [[ -n "$upload_dir" ]] || api_die bad_request "--dir <upload dir> required"
                ( uploads_resolve_site "$name" >/dev/null 2>&1 && uploads_require_dir "$upload_dir" >/dev/null 2>&1 ) \
                    || api_die bad_request "'$upload_dir' isn't one of '$name's upload dirs"
                argv=(uploads-import "$name" --dir "$upload_dir" --from-backup --yes ${backup_version:+--version "$backup_version"}) ;;
        esac
    elif [[ "$kind" == uploads-restore ]]; then
        [[ -n "$snapshot" ]] || api_die bad_request "--snapshot <id> required"
        argv=(uploads-import "$name" --snapshot "$snapshot" --yes)
    elif [[ "$kind" == uploads-snapshot ]]; then
        argv=(uploads-snapshot "$name")
    elif [[ "$kind" == db-import ]]; then
        local spool
        spool="$(api_spool_import "$id")"
        argv=(db-import "$name" --from-file "$spool" --yes --delete-file)
    else
        api_valid api_valid_repo_url "$url"
        is_provisioned "$name" && api_die conflict "'$name' is already provisioned"
        # A failed first provision leaves its checkout behind, and re-running
        # provision is the normal way to finish it — but only for the same
        # repo: anything else under that name is not ours to build on.
        if [[ -e "$(site_root "$name")" ]]; then
            local origin
            origin="$(git -c safe.directory='*' -C "$(site_dir "$name")" remote get-url origin 2>/dev/null || true)"
            [[ -n "$origin" && "$origin" == "$url" ]] \
                || api_die conflict "'$(site_root "$name")' already exists and isn't a checkout of $url — remove it from the CLI first"
        fi
        # Both bound to fail inside provision; refuse up front.
        local f
        for f in "${flags[@]}"; do
            [[ "$f" == --auth && " ${flags[*]} " == *" --no-auth "* ]] && api_die bad_request "--auth and --no-auth are mutually exclusive"
            [[ "$f" == --build && " ${flags[*]} " == *" --no-build "* ]] && api_die bad_request "--build and --no-build are mutually exclusive"
        done
        argv=(provision "$name" "$url" --non-interactive "${flags[@]}")
    fi

    mkdir -p "$RUNS_META_DIR" "$RUNS_LOG_DIR"
    chmod 700 "$RUNS_META_DIR"
    chmod 750 "$RUNS_LOG_DIR"
    local log="$RUNS_LOG_DIR/$id.log"
    : > "$log"
    chmod 640 "$log"
    printf '{"run_id":%s,"kind":%s,"site":%s,"argv":%s,"actor":%s,"submitted_at":%s}\n' \
        "$(json_str "$id")" "$(json_str "$kind")" "$(json_str "$run_site")" "$(json_str_array "${argv[@]}")" \
        "$(json_str "$actor")" "$(json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" > "$RUNS_META_DIR/$id.json"

    local trigger="web ($actor)"
    if command -v systemd-run >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        # A transient unit, not a child of this process: the run outlives
        # the web request, and a restart of the web app, and shows up in
        # `systemctl list-units 'ddeploy-run-*'`.
        systemd-run --quiet --collect --unit "ddeploy-run-$id" \
            --description "ddeploy $kind $run_site (run $id)" \
            --property "StandardOutput=append:$log" --property "StandardError=append:$log" \
            --setenv "DDEPLOY_RUN_ID=$id" --setenv DDEPLOY_RUN_LOG_EXTERNAL=1 \
            --setenv "DDEPLOY_TRIGGER=$trigger" --setenv HOME=/root --setenv NO_COLOR=1 \
            -- "$PROVISIONER_DIR/provision.sh" "${argv[@]}" >/dev/null \
            || api_die unavailable "systemd-run failed to start the run"
    else
        DDEPLOY_RUN_ID="$id" DDEPLOY_RUN_LOG_EXTERNAL=1 DDEPLOY_TRIGGER="$trigger" NO_COLOR=1 \
            setsid -f "$PROVISIONER_DIR/provision.sh" "${argv[@]}" >> "$log" 2>&1 < /dev/null
    fi
    api_header
    printf ',"run_id":%s,"site":%s}\n' "$(json_str "$id")" "$(json_str "$run_site")"
}

api_run_show() {
    local id="${1:-}"
    [[ $# -eq 1 ]] || api_die bad_request "run show takes one run id"
    api_valid validate_run_id "$id"
    local meta=null log="$RUNS_LOG_DIR/$id.log" log_size=null
    [[ -s "$RUNS_META_DIR/$id.json" ]] && meta="$(head -n 1 "$RUNS_META_DIR/$id.json")"
    [[ -f "$log" ]] && log_size="$(stat -c %s "$log")"
    local events="[]"
    if compgen -G "$EVENTS_DIR/*.jsonl" >/dev/null; then
        events="$(cat "$EVENTS_DIR"/*.jsonl | { grep -F "\"run_id\":\"$id\"" || true; } | sort -s -t, -k1,1 | json_lines_to_array)"
    fi
    if [[ "$meta" == null && "$log_size" == null && "$events" == "[]" ]]; then
        api_die not_found "no run '$id'"
    fi
    local cancelled_by=""
    [[ -s "$RUNS_META_DIR/$id.cancelled" ]] && cancelled_by="$(head -n 1 "$RUNS_META_DIR/$id.cancelled")"
    local load="" active="" result=""
    if command -v systemctl >/dev/null 2>&1; then
        local props
        props="$(systemctl show "ddeploy-run-$id.service" -p LoadState -p ActiveState -p Result 2>/dev/null || true)"
        load="$(sed -n 's/^LoadState=//p' <<< "$props")"
        active="$(sed -n 's/^ActiveState=//p' <<< "$props")"
        result="$(sed -n 's/^Result=//p' <<< "$props")"
    fi
    api_header
    printf ',"run_id":%s,"meta":%s,"events":%s,"unit":{"load_state":%s,"active_state":%s,"result":%s},"log_size":%s,"cancelled_by":%s}\n' \
        "$(json_str "$id")" "$meta" "$events" "$(json_str_or_null "$load")" "$(json_str_or_null "$active")" \
        "$(json_str_or_null "$result")" "$log_size" "$(json_str_or_null "$cancelled_by")"
}

api_run_log() {
    local id="${1:-}"
    shift || true
    api_valid validate_run_id "$id"
    api_parse_read_opts "$@"
    local file="$RUNS_LOG_DIR/$id.log"
    [[ -f "$file" ]] || api_die not_found "no output log for run '$id'"
    api_header
    printf ',"run_id":%s' "$(json_str "$id")"
    api_read_file "$file" "$API_READ_OFFSET" "$API_READ_LINES"
    printf '}\n'
}

# Copies the dump on stdin to a root-only spool file for run $1 and
# prints its path. Refused: empty, larger than WEB_IMPORT_MAX_MB, or
# neither gzip nor plain text (a NUL byte in the first 64 KB).
api_spool_import() {
    local id="$1"
    [[ ! -t 0 ]] || api_die bad_request "db-import reads the dump from stdin"
    mkdir -p "$DB_IMPORTS_DIR"
    chmod 700 "$DB_IMPORTS_DIR"
    find "$DB_IMPORTS_DIR" -maxdepth 1 -type f -mtime +1 -delete 2>/dev/null || true
    local max; max="$(api_import_max_bytes)"
    local tmp="$DB_IMPORTS_DIR/$id.upload"
    ( umask 077; head -c "$((max + 1))" > "$tmp" )
    local size; size="$(stat -c %s "$tmp")"
    if (( size == 0 )); then rm -f "$tmp"; api_die bad_request "the dump is empty"; fi
    if (( size > max )); then rm -f "$tmp"; api_die bad_request "the dump is larger than the $((max / 1024 / 1024)) MB limit (WEB_IMPORT_MAX_MB)"; fi
    local magic; magic="$(head -c 2 "$tmp" | od -An -tx1 | tr -d ' \n')"
    local out
    if [[ "$magic" == 1f8b ]]; then
        out="$DB_IMPORTS_DIR/$id.sql.gz"
    elif ! head -c 65536 "$tmp" | tr -d '\000' | cmp -s - <(head -c 65536 "$tmp"); then
        rm -f "$tmp"
        api_die bad_request "that isn't a .sql or .sql.gz dump (binary content)"
    else
        out="$DB_IMPORTS_DIR/$id.sql"
    fi
    mv "$tmp" "$out"
    printf '%s' "$out"
}

api_run_cancel() {
    local id="${1:-}"
    [[ $# -le 3 ]] || api_die bad_request "run cancel takes one run id"
    api_valid validate_run_id "$id"
    shift
    local actor=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --actor) actor="${2:-}"; shift ;;
            *) api_die bad_request "run cancel: unexpected argument '$1'" ;;
        esac
        shift
    done
    api_valid api_valid_actor "$actor"
    [[ -s "$RUNS_META_DIR/$id.json" ]] || api_die not_found "no run '$id' started through the api (CLI and webhook runs can't be cancelled here)"
    local unit="ddeploy-run-$id.service" state
    state="$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || true)"
    [[ "$state" == active || "$state" == activating ]] || api_die conflict "run '$id' isn't running"
    printf '%s cancelled by %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$actor" >> "$RUNS_LOG_DIR/$id.log"
    printf '%s\n' "$actor" > "$RUNS_META_DIR/$id.cancelled"
    systemctl stop "$unit" || api_die unavailable "systemctl stop $unit failed"
    api_header
    printf ',"run_id":%s,"cancelled":true}\n' "$(json_str "$id")"
}

# --- env ----------------------------------------------------------------

api_env_json() {
    local file="$1" line key first=1 other=0
    printf ',"path":%s,"entries":[' "$(json_str "$file")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            key="${line%%=*}"
            [[ "$first" -eq 1 ]] || printf ','
            first=0
            printf '{"key":%s,"value":%s,"managed":%s}' "$(json_str "$key")" "$(json_str "${line#*=}")" \
                "$([[ "$key" =~ ^(CRAFT_)?DB_ ]] && echo true || echo false)"
        elif [[ -n "${line//[[:space:]]/}" && "$line" != \#* ]]; then
            other=$((other + 1))
        fi
    done < "$file"
    printf '],"unparsed_lines":%s' "$other"
}

api_env() {
    local name="${1:-}"
    shift || true
    local apply=0 actor=""
    local -a unsets=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apply) apply=1 ;;
            --unset) unsets+=("${2:-}"); shift ;;
            --actor) actor="${2:-}"; shift ;;
            *) api_die bad_request "env: unexpected argument '$1'" ;;
        esac
        shift
    done
    api_require_site "$name"
    local file
    file="$( (env_file_for_site "$name") 2>&1 )" || api_die conflict "$(sed 's/^\[error\] *//' <<< "$file" | tail -n 1)"

    if [[ "$apply" -eq 1 ]]; then
        api_valid api_valid_actor "$actor"
        local -a sets=() keys=()
        local line key
        # Values come on stdin, never argv: argv shows up in `ps` for every
        # user on the box, and these are secrets.
        if [[ ! -t 0 ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -n "$line" ]] || continue
                [[ "$line" == *=* ]] || api_die bad_request "stdin lines must be KEY=value"
                key="${line%%=*}"
                api_valid env_validate_key "$key"
                [[ "$line" != *$'\r'* ]] || api_die bad_request "value for $key contains a carriage return"
                sets+=("$line")
                keys+=("$key")
            done
        fi
        for key in "${unsets[@]}"; do api_valid env_validate_key "$key"; done
        [[ "${#sets[@]}" -gt 0 || "${#unsets[@]}" -gt 0 ]] || api_die bad_request "nothing to change"
        local owner; owner="$(env_owner_for_site "$name")"
        touch "$file"
        local kv
        for kv in "${sets[@]}"; do write_env_var "$file" "${kv%%=*}" "${kv#*=}"; done
        for key in "${unsets[@]}"; do unset_env_var "$file" "$key"; done
        env_fix_perms "$file" "$owner"
        local summary=""
        [[ "${#keys[@]}" -gt 0 ]] && summary="set ${keys[*]}"
        [[ "${#unsets[@]}" -gt 0 ]] && summary="${summary:+$summary; }unset ${unsets[*]}"
        DDEPLOY_TRIGGER="web ($actor)" site_log "$name" "env: $summary (web ($actor))"
        DDEPLOY_TRIGGER="web ($actor)" event_record "$name" env-change succeeded "subject=$summary"
    fi
    api_header
    api_env_json "$file"
    printf '}\n'
}

# --- settings -----------------------------------------------------------

# What `api settings` may override: OVERRIDE_*_KEYS (lib/cmd_override.sh)
# minus db_env_scheme and persistent_files, which rewire where the site
# keeps its database credentials and data — CLI-only, on purpose.
API_SETTING_KEYS="basic_auth client_max_body_size fpm_max_children security_headers static_cache deny_php_in_uploads db_backup_retention_days nodejs_version build composer_dev additional_hostnames additional_fqdns auth_exempt_paths deny_php_paths backup_exclude preview_branches"

api_settings() {
    local name="${1:-}"
    shift || true
    local actor="" branch="" clear_branch=0
    local -a sets=() unsets=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --set) sets+=("${2:-}"); shift ;;
            --unset) unsets+=("${2:-}"); shift ;;
            --branch) branch="${2:-}"; shift ;;
            --clear-branch) clear_branch=1 ;;
            --actor) actor="${2:-}"; shift ;;
            *) api_die bad_request "settings: unexpected argument '$1'" ;;
        esac
        shift
    done
    api_require_site "$name"
    api_valid api_valid_actor "$actor"
    [[ "${#sets[@]}" -gt 0 || "${#unsets[@]}" -gt 0 || -n "$branch" || "$clear_branch" -eq 1 ]] || api_die bad_request "nothing to change"
    [[ -z "$branch" || "$clear_branch" -eq 0 ]] || api_die bad_request "--branch and --clear-branch are mutually exclusive"
    local kv key
    for kv in "${sets[@]}" "${unsets[@]}"; do
        key="${kv%%=*}"
        [[ " $API_SETTING_KEYS " == *" $key "* ]] || api_die bad_request "'$key' can't be changed here (allowed: $API_SETTING_KEYS)"
    done
    for kv in "${sets[@]}"; do
        [[ "$kv" == *=* ]] || api_die bad_request "--set takes key=value"
        local val="${kv#*=}" v
        if [[ "$(override_key_kind "${kv%%=*}")" == array ]]; then
            for v in $val; do api_valid override_validate_value "$name" "${kv%%=*}" "$v"; done
        else
            api_valid override_validate_value "$name" "${kv%%=*}" "$val"
        fi
    done
    if [[ -n "$branch" ]]; then
        api_valid validate_branch_name "$branch" "--branch"
        is_preview "$name" && api_die bad_request "a preview's branch is fixed — it's part of what the preview is"
        local remote
        remote="$(GIT_SSH_COMMAND="$(git_ssh_command)" timeout 30 git -c safe.directory='*' -C "$(site_dir "$name")" ls-remote origin "refs/heads/$branch" 2>/dev/null || true)"
        [[ -n "$remote" ]] || api_die bad_request "branch '$branch' doesn't exist on the remote"
    fi

    local -a args=("$name")
    for kv in "${sets[@]}"; do args+=("$kv"); done
    for key in "${unsets[@]}"; do args+=(--unset "$key"); done
    if [[ "${#sets[@]}" -gt 0 || "${#unsets[@]}" -gt 0 ]]; then
        cmd_override "${args[@]}" >/dev/null
    fi
    [[ -n "$branch" ]] && write_deploy_branch "$name" "$branch"
    [[ "$clear_branch" -eq 1 ]] && clear_deploy_branch "$name"

    local summary="" k
    for kv in "${sets[@]}"; do summary+="${summary:+, }${kv%%=*}=${kv#*=}"; done
    for k in "${unsets[@]}"; do summary+="${summary:+, }reset $k"; done
    [[ -n "$branch" ]] && summary+="${summary:+, }branch=$branch"
    [[ "$clear_branch" -eq 1 ]] && summary+="${summary:+, }branch reset"
    DDEPLOY_TRIGGER="web ($actor)" site_log "$name" "settings: $summary (web ($actor)) — applies on next deploy"
    DDEPLOY_TRIGGER="web ($actor)" event_record "$name" settings-change succeeded "subject=$summary"
    api_site "$name"
}

# --- branches / commits -------------------------------------------------

api_branches() {
    local name="${1:-}"
    [[ $# -le 1 ]] || api_die bad_request "branches takes one site name"
    api_require_site "$name"
    local refs
    refs="$(GIT_SSH_COMMAND="$(git_ssh_command)" GIT_TERMINAL_PROMPT=0 timeout 30 \
        git -c safe.directory='*' -C "$(site_dir "$name")" ls-remote --symref origin HEAD 'refs/heads/*' 2>/dev/null)" \
        || api_die unavailable "couldn't list the remote's branches (git ls-remote failed)"
    local default="" line
    local -a branches=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^ref:\ refs/heads/([^[:space:]]+)[[:space:]]+HEAD$ ]]; then default="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[0-9a-f]{40}[[:space:]]+refs/heads/(.+)$ ]]; then branches+=("${BASH_REMATCH[1]}")
        fi
    done <<< "$refs"
    api_header
    printf ',"default_branch":%s,"tracked":%s,"branches":%s}\n' "$(json_str_or_null "$default")" \
        "$(json_str_or_null "$(read_deploy_branch "$name" 2>/dev/null || true)")" "$(json_str_array "${branches[@]}")"
}

api_commit_rows() {
    local dir="$1" range="$2" first=1 sha author date subject
    printf '['
    while IFS=$'\x1f' read -r sha author date subject; do
        [[ -n "$sha" ]] || continue
        [[ "$first" -eq 1 ]] || printf ','
        first=0
        printf '{"sha":%s,"author":%s,"date":%s,"subject":%s}' "$(json_str "$sha")" "$(json_str "$author")" "$(json_str "$date")" "$(json_str "$subject")"
    done < <(git -c safe.directory='*' -C "$dir" log --max-count=100 --format='%H%x1f%an%x1f%aI%x1f%s' "$range" 2>/dev/null)
    printf ']'
}

api_commits() {
    local name="${1:-}" from="${2:-}" to="${3:-}"
    [[ $# -eq 3 ]] || api_die bad_request "commits takes <name> <from-sha> <to-sha>"
    api_require_site "$name"
    [[ "$from" =~ ^[0-9a-f]{7,40}$ && "$to" =~ ^[0-9a-f]{7,40}$ ]] || api_die bad_request "from and to must be commit SHAs"
    local dir; dir="$(site_dir "$name")"
    local known=true
    git -c safe.directory='*' -C "$dir" cat-file -e "$from^{commit}" 2>/dev/null && git -c safe.directory='*' -C "$dir" cat-file -e "$to^{commit}" 2>/dev/null || known=false
    api_header
    printf ',"from":%s,"to":%s,"known":%s' "$(json_str "$from")" "$(json_str "$to")" "$known"
    if [[ "$known" == true ]]; then
        # ahead: what the deploy brought in; behind: what it took away (a
        # rollback, or a force-pushed branch).
        printf ',"ahead":%s,"behind":%s}\n' "$(api_commit_rows "$dir" "$from..$to")" "$(api_commit_rows "$dir" "$to..$from")"
    else
        printf ',"ahead":[],"behind":[]}\n'
    fi
}

# --- db -----------------------------------------------------------------

api_db() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        info) api_db_info "$@" ;;
        credentials) api_db_credentials "$@" ;;
        *) api_die bad_request "db: expected info, credentials or dump" ;;
    esac
}

api_db_info() {
    local name="${1:-}"
    [[ $# -le 1 ]] || api_die bad_request "db info takes one site name"
    api_require_site "$name"
    db_resolve_site "$name"
    local rows="" err=""
    if [[ -z "$DBX_PASS" ]]; then
        err="no DB credentials on file for '$DBX_TARGET'"
    else
        rows="$(mysql_as_user "$DBX_USER" "$DBX_PASS" -h "$DBX_HOST" -N -B "$DBX_NAME" -e \
            "SELECT table_name, IFNULL(table_rows,0), IFNULL(data_length,0)+IFNULL(index_length,0) FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY 3 DESC" 2>&1)" \
            || { err="couldn't query the database as '$DBX_USER': $(tail -n 1 <<< "$rows")"; rows=""; }
    fi
    local total=0 count=0 first=1 t r b tables="["
    while IFS=$'\t' read -r t r b; do
        [[ -n "$t" ]] || continue
        count=$((count + 1))
        total=$((total + b))
        if (( count <= 100 )); then
            [[ "$first" -eq 1 ]] || tables+=","
            first=0
            tables+="{\"name\":$(json_str "$t"),\"rows\":$(json_num "$r"),\"bytes\":$(json_num "$b")}"
        fi
    done <<< "$rows"
    tables+="]"
    local snaps="[" id bytes reason first_s=1
    while IFS=$'\t' read -r id bytes reason; do
        [[ -n "$id" ]] || continue
        [[ "$first_s" -eq 1 ]] || snaps+=","
        first_s=0
        snaps+="{\"id\":$(json_str "$id"),\"bytes\":$(json_num "$bytes"),\"reason\":$(json_str "$reason"),\"created_at\":$(json_str "${id:0:4}-${id:4:2}-${id:6:2}T${id:9:2}:${id:11:2}:${id:13:2}Z")}"
    done < <(db_snapshot_list "$DBX_TARGET")
    snaps+="]"
    api_header
    printf ',"site":%s,"target":%s,"database":%s,"user":%s,"host":%s,"scheme":%s' "$(json_str "$name")" "$(json_str "$DBX_TARGET")" \
        "$(json_str "$DBX_NAME")" "$(json_str "$DBX_USER")" "$(json_str "$DBX_HOST")" "$(json_str "$DBX_SCHEME")"
    printf ',"error":%s,"size_bytes":%s,"table_count":%s,"tables":%s,"snapshots":%s}\n' "$(json_str_or_null "$err")" \
        "$( [[ -n "$err" ]] && echo null || echo "$total")" "$( [[ -n "$err" ]] && echo null || echo "$count")" "$tables" "$snaps"
}

api_db_credentials() {
    local name="${1:-}"
    [[ $# -le 1 ]] || api_die bad_request "db credentials takes one site name"
    api_require_site "$name"
    db_resolve_site "$name"
    [[ -n "$DBX_PASS" ]] || api_die not_found "no DB credentials on file for '$DBX_TARGET'"
    api_header
    printf ',"host":%s,"port":3306,"database":%s,"user":%s,"password":%s}\n' "$(json_str "$DBX_HOST")" \
        "$(json_str "$DBX_NAME")" "$(json_str "$DBX_USER")" "$(json_str "$DBX_PASS")"
}

# Streams a gzipped dump of <name>'s database (or one of its snapshots)
# to stdout. Validation errors are the usual JSON error and exit 1, with
# nothing written before them.
api_db_dump() {
    local errf; errf="$(mktemp)"
    local name="${1:-}" snapshot=""
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --snapshot) snapshot="${2:-}"; shift ;;
            *) snapshot="?$1" ;;
        esac
        shift
    done
    local rc=0 src=""
    set +e
    src="$( {
        set -e
        API_ERR_CODE_FILE="$errf.code"
        [[ "$snapshot" != \?* ]] || api_die bad_request "db dump: unexpected argument '${snapshot#\?}'"
        load_conf
        require_root
        PARSE_CONFIG_QUIET=1
        api_require_site "$name"
        db_resolve_site "$name"
        if [[ -n "$snapshot" ]]; then
            api_valid validate_snapshot_id "$snapshot"
            [[ -f "$(db_snapshot_dir "$DBX_TARGET")/$snapshot.sql.gz" ]] || api_die not_found "no snapshot '$snapshot'"
            printf 'file\t%s\n' "$(db_snapshot_dir "$DBX_TARGET")/$snapshot.sql.gz"
        else
            printf 'db\t%s\n' "$DBX_NAME"
        fi
    } 2>"$errf" )"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        local msg; msg="$(grep -E '^\[error\]' "$errf" | tail -n 1 | sed 's/^\[error\] *//' || true)"
        printf '{"api_version":%s,"error":{"code":%s,"message":%s}}\n' "$API_VERSION" \
            "$(json_str "$(cat "$errf.code" 2>/dev/null || echo error)")" "$(json_str "${msg:-db dump failed}")"
        rm -f "$errf" "$errf.code"
        return 1
    fi
    rm -f "$errf" "$errf.code"
    load_conf
    if [[ "${src%%$'\t'*}" == file ]]; then
        cat "${src#*$'\t'}"
    else
        dump_database "${src#*$'\t'}" /dev/stdout
    fi
}

# --- uploads ------------------------------------------------------------

# Like api_spool_import, for an uploads archive: .zip, .tar or .tar.gz,
# up to WEB_UPLOAD_MAX_MB. Content is checked member by member later, by
# lib/uploads_extract.py; this only refuses what's obviously not one.
api_spool_upload() {
    local id="$1"
    [[ ! -t 0 ]] || api_die bad_request "uploads-import reads the archive from stdin"
    mkdir -p "$DB_IMPORTS_DIR"
    chmod 700 "$DB_IMPORTS_DIR"
    find "$DB_IMPORTS_DIR" -maxdepth 1 -type f -mtime +1 -delete 2>/dev/null || true
    local max; max="$(api_upload_max_bytes)"
    local out="$DB_IMPORTS_DIR/$id.upload-archive"
    ( umask 077; head -c "$((max + 1))" > "$out" )
    local size; size="$(stat -c %s "$out")"
    if (( size == 0 )); then rm -f "$out"; api_die bad_request "the archive is empty"; fi
    if (( size > max )); then rm -f "$out"; api_die bad_request "the archive is larger than the $((max / 1024 / 1024)) MB limit (WEB_UPLOAD_MAX_MB)"; fi
    local magic; magic="$(head -c 4 "$out" | od -An -tx1 | tr -d ' \n')"
    local ustar; ustar="$(dd if="$out" bs=1 skip=257 count=5 2>/dev/null)"
    if [[ "$magic" != 1f8b* && "$magic" != 504b0304 && "$magic" != 504b0506 && "$ustar" != ustar ]]; then
        rm -f "$out"
        api_die bad_request "that isn't a .zip, .tar or .tar.gz archive"
    fi
    printf '%s' "$out"
}

api_uploads() {
    local name="${1:-}"
    [[ $# -le 1 ]] || api_die bad_request "uploads takes one site name"
    api_require_site "$name"
    uploads_resolve_site "$name"
    local -a objs=()
    local d path files bytes exists
    for d in "${UPLOAD_DIRS[@]}"; do
        path="$(uploads_path "$d")"
        files=null bytes=null exists=false
        if [[ -d "$path" ]]; then
            exists=true
            # Bounded: a media library with a million files mustn't hang
            # the page. null = didn't finish counting.
            files="$(timeout 10 find "$path" -type f 2>/dev/null | wc -l || true)"
            bytes="$(timeout 10 du -sb "$path" 2>/dev/null | cut -f1 || true)"
            [[ "$files" =~ ^[0-9]+$ ]] || files=null
            [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=null
        fi
        objs+=("{\"dir\":$(json_str "$d"),\"path\":$(json_str "$path"),\"exists\":$exists,\"files\":$files,\"bytes\":$bytes}")
    done
    local snaps="[" first=1 id sdir reason
    while IFS=$'\t' read -r id sdir reason; do
        [[ -n "$id" ]] || continue
        [[ "$first" -eq 1 ]] || snaps+=","
        first=0
        snaps+="{\"id\":$(json_str "$id"),\"dir\":$(json_str "$sdir"),\"reason\":$(json_str "$reason"),\"created_at\":$(json_str "${id:0:4}-${id:4:2}-${id:6:2}T${id:9:2}:${id:11:2}:${id:13:2}Z")}"
    done < <(uploads_snapshot_list)
    snaps+="]"
    api_header
    printf ',"site":%s,"target":%s,"dirs":' "$(json_str "$name")" "$(json_str "$UPX_TARGET")"
    printf '%s\n' "${objs[@]}" | json_lines_to_array
    printf ',"snapshots":%s,"max_bytes":%s}\n' "$snaps" "$(api_upload_max_bytes)"
}

# Streams one upload dir as a .tar.gz. Validation errors are the usual
# JSON error, before any output.
api_uploads_download() {
    local errf; errf="$(mktemp)"
    local name="${1:-}" dir=""
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir) dir="${2:-}"; shift ;;
            *) dir="?$1" ;;
        esac
        shift
    done
    local rc=0 path=""
    set +e
    path="$( {
        set -e
        API_ERR_CODE_FILE="$errf.code"
        [[ "$dir" != \?* ]] || api_die bad_request "uploads download: unexpected argument '${dir#\?}'"
        [[ -n "$dir" ]] || api_die bad_request "--dir <upload dir> required"
        load_conf
        require_root
        PARSE_CONFIG_QUIET=1
        api_require_site "$name"
        uploads_resolve_site "$name"
        api_valid uploads_require_dir "$dir"
        [[ -d "$(uploads_path "$dir")" ]] || api_die not_found "'$dir' has no files yet"
        uploads_path "$dir"
    } 2>"$errf" )"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        local msg; msg="$(grep -E '^\[error\]' "$errf" | tail -n 1 | sed 's/^\[error\] *//' || true)"
        printf '{"api_version":%s,"error":{"code":%s,"message":%s}}\n' "$API_VERSION" \
            "$(json_str "$(cat "$errf.code" 2>/dev/null || echo error)")" "$(json_str "${msg:-uploads download failed}")"
        rm -f "$errf" "$errf.code"
        return 1
    fi
    rm -f "$errf" "$errf.code"
    tar -czf - -C "$path" .
}

# --- backups (object storage) -------------------------------------------

# Dies unless backups are set up, and the site has its own backups:
# a shared-mode preview's data — and so its backups — are its parent's.
api_backups_require_target() {
    local name="$1" kind="${2:-}"
    if is_preview "$name" && read_preview_meta "$name" && [[ "$PREVIEW_MODE" == shared ]]; then
        api_die bad_request "'$name' is a shared-mode preview: its database and files are '$PREVIEW_PROJECT's — use '$PREVIEW_PROJECT's backups"
    fi
    case "$kind" in
        backup-database|backup-restore-db) [[ "$DB_BACKUP_ENABLED" == true ]] || api_die bad_request "database backups are off on this server (DB_BACKUP_ENABLED)" ;;
        backup-uploads|backup-restore-uploads) [[ "$BACKUP_ENABLED" == true ]] || api_die bad_request "uploads backups are off on this server (BACKUP_ENABLED)" ;;
    esac
    [[ -n "$BACKUP_CREDENTIALS" && -f "$BACKUP_CREDENTIALS" && -n "$BACKUP_BUCKET" ]] \
        || api_die bad_request "object storage isn't configured (BACKUP_CREDENTIALS, BACKUP_BUCKET)"
}

# rclone lsjson output (one prefix) -> {"file","bytes","created_at","kept"} lines.
api_backup_dump_rows() {
    local kept="$1"
    python3 -c '
import json, sys, re
kept = sys.argv[1] == "true"
for e in json.load(sys.stdin):
    if e.get("IsDir"):
        continue
    name = e["Name"]
    m = re.search(r"(\d{8})-(\d{6})", name)
    created = (f"{m[1][:4]}-{m[1][4:6]}-{m[1][6:]}T{m[2][:2]}:{m[2][2:4]}:{m[2][4:]}Z" if m else e.get("ModTime"))
    print(json.dumps({"file": name, "bytes": e.get("Size"), "created_at": created, "kept": kept}))
' "$kept"
}

api_backups() {
    local sub="${1:-}"
    case "$sub" in
        keep|unkeep|delete) shift; api_backups_manage "$sub" "$@"; return ;;
    esac
    local name="${1:-}"
    [[ $# -le 1 ]] || api_die bad_request "backups takes one site name"
    api_require_site "$name"
    local target; target="$(restore_target "$name")"
    local configured=false
    [[ -n "$BACKUP_CREDENTIALS" && -f "$BACKUP_CREDENTIALS" && -n "$BACKUP_BUCKET" ]] && command -v rclone >/dev/null 2>&1 && configured=true

    # Effective retention: the site's own db_backup_retention_days, else
    # the server's. Read the same way backup-database does.
    local retention="$DB_BACKUP_RETENTION_DAYS" retention_source=server
    if ( uploads_resolve_site "$name" ) >/dev/null 2>&1; then
        uploads_resolve_site "$name" >/dev/null 2>&1
        if [[ -n "${DB_BACKUP_RETENTION_DAYS_CONFIG:-}" ]]; then retention="$DB_BACKUP_RETENTION_DAYS_CONFIG"; retention_source=site; fi
    fi

    local dumps="[]" mirror="[]" versions="[]" error=""
    if [[ "$configured" == true ]]; then
        local remote; remote="$(backup_remote_spec)"
        local raw rows="" fixed
        if fixed="$(backup_endpoint_with_bucket "$(backup_endpoint)" "$BACKUP_BUCKET")"; then
            error="BACKUP_ENDPOINT includes the bucket name, so backups are filed under $BACKUP_BUCKET/$BACKUP_BUCKET/ and none can be listed here. On the server: set BACKUP_ENDPOINT=\"$fixed\" in $BACKUP_CREDENTIALS, then rclone move $remote/$BACKUP_BUCKET $remote"
        fi
        if [[ -n "$error" ]]; then
            :
        elif raw="$(timeout 60 rclone lsjson "${remote}/$target/db/" 2>&1)"; then
            rows+="$(api_backup_dump_rows false <<< "$raw")"$'\n'
        elif [[ "$raw" != *"directory not found"* ]]; then
            error="couldn't list $BACKUP_BUCKET: $(tail -n 1 <<< "$raw")"
        fi
        if raw="$(timeout 60 rclone lsjson "${remote}/$target/db-kept/" 2>/dev/null)"; then
            rows+="$(api_backup_dump_rows true <<< "$raw")"
        fi
        dumps="$({ grep -v '^$' <<< "$rows" || true; } | sort -r | json_lines_to_array)"

        local -a dirs_json=()
        local d size_json count bytes
        for d in "${UPLOAD_DIRS[@]}"; do
            size_json="$(timeout 30 rclone size --json "${remote}/$target/$d" 2>/dev/null || true)"
            count="$(sed -nE 's/.*"count": ?([0-9]+).*/\1/p' <<< "$size_json")"
            bytes="$(sed -nE 's/.*"bytes": ?([0-9]+).*/\1/p' <<< "$size_json")"
            dirs_json+=("{\"dir\":$(json_str "$d"),\"files\":$(json_num "$count"),\"bytes\":$(json_num "$bytes")}")
        done
        mirror="$(printf '%s\n' "${dirs_json[@]}" | json_lines_to_array)"

        local v first=1
        versions="["
        while IFS= read -r v; do
            v="${v%/}"
            [[ "$v" =~ $UPLOADS_VERSION_ID_RE ]] || continue
            local vdirs; vdirs="$(timeout 20 rclone lsf --dirs-only -R --max-depth 4 "${remote}/$target/.versions/$v/" 2>/dev/null | sed 's#/$##' || true)"
            local -a in_version=()
            for d in "${UPLOAD_DIRS[@]}"; do grep -qxF "$d" <<< "$vdirs" && in_version+=("$d"); done
            [[ "$first" -eq 1 ]] || versions+=","
            first=0
            versions+="{\"id\":$(json_str "$v"),\"created_at\":$(json_str "${v:0:4}-${v:4:2}-${v:6:2}T${v:9:2}:${v:11:2}:${v:13:2}Z"),\"dirs\":$(json_str_array "${in_version[@]}")}"
        done < <(timeout 30 rclone lsf --dirs-only "${remote}/$target/.versions/" 2>/dev/null | sort -r)
        versions+="]"
    fi

    # Last backup runs, from this site's history.
    local f="$EVENTS_DIR/$target.jsonl" last_db=null last_up=null
    if [[ -s "$f" ]]; then
        last_db="$(grep -E '"kind":"backup-database","phase":"(succeeded|failed)"' "$f" | tail -n 1 || true)"
        last_up="$(grep -E '"kind":"backup-uploads","phase":"(succeeded|failed)"' "$f" | tail -n 1 || true)"
        [[ -n "$last_db" ]] || last_db=null
        [[ -n "$last_up" ]] || last_up=null
    fi
    local shared=false
    [[ "$target" != "$name" ]] && shared=true

    api_header
    printf ',"site":%s,"target":%s,"shared_with_parent":%s,"configured":%s,"bucket":%s,"error":%s' \
        "$(json_str "$name")" "$(json_str "$target")" "$shared" "$configured" "$(json_str_or_null "$BACKUP_BUCKET")" "$(json_str_or_null "$error")"
    printf ',"database":{"enabled":%s,"schedule":%s,"retention_days":%s,"retention_source":%s,"dumps":%s,"last_run":%s}' \
        "$(json_bool "$DB_BACKUP_ENABLED")" "$(json_str "$DB_BACKUP_SCHEDULE")" "$(json_num "$retention")" "$(json_str "$retention_source")" "$dumps" "$last_db"
    printf ',"uploads":{"enabled":%s,"schedule":%s,"versions_days":%s,"mirror":%s,"versions":%s,"last_run":%s}}\n' \
        "$(json_bool "$BACKUP_ENABLED")" "$(json_str "$BACKUP_SCHEDULE")" "$(json_num "$UPLOADS_BACKUP_VERSIONS_DAYS")" "$mirror" "$versions" "$last_up"
}

# keep: move a dump to db-kept/ (never pruned); unkeep: back to db/
# (pruned by age again); delete: remove it.
api_backups_manage() {
    local action="$1" name="${2:-}" file="" actor=""
    shift 2 || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file) file="${2:-}"; shift ;;
            --actor) actor="${2:-}"; shift ;;
            *) api_die bad_request "backups $action: unexpected argument '$1'" ;;
        esac
        shift
    done
    api_require_site "$name"
    api_valid api_valid_actor "$actor"
    api_valid validate_backup_dump_name "$file"
    api_backups_require_target "$name"
    local target; target="$(restore_target "$name")"
    local remote; remote="$(backup_remote_spec)"
    local prefix; prefix="$(backup_dump_prefix "$remote" "$target" "$file")" || api_die not_found "no backup '$file' for '$target'"
    case "$action" in
        keep)
            [[ "$prefix" == db ]] || api_die conflict "'$file' is already kept"
            rclone moveto "${remote}/$target/db/$file" "${remote}/$target/db-kept/$file" || api_die unavailable "couldn't move '$file'" ;;
        unkeep)
            [[ "$prefix" == db-kept ]] || api_die conflict "'$file' isn't kept"
            rclone moveto "${remote}/$target/db-kept/$file" "${remote}/$target/db/$file" || api_die unavailable "couldn't move '$file'" ;;
        delete)
            rclone deletefile "${remote}/$target/$prefix/$file" || api_die unavailable "couldn't delete '$file'" ;;
    esac
    DDEPLOY_TRIGGER="web ($actor)" site_log "$target" "backups: $action $file (web ($actor))"
    DDEPLOY_TRIGGER="web ($actor)" event_record "$target" "backup-$action" succeeded "subject=$file"
    api_header
    printf ',"file":%s,"action":%s}\n' "$(json_str "$file")" "$(json_str "$action")"
}

# Streams one backed-up dump. Validation errors are the usual JSON error,
# before any output.
api_backups_download() {
    local errf; errf="$(mktemp)"
    local name="${1:-}" file=""
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file) file="${2:-}"; shift ;;
            *) file="?$1" ;;
        esac
        shift
    done
    local rc=0 src=""
    set +e
    src="$( {
        set -e
        API_ERR_CODE_FILE="$errf.code"
        [[ "$file" != \?* ]] || api_die bad_request "backups download: unexpected argument '${file#\?}'"
        load_conf
        require_root
        api_require_site "$name"
        api_valid validate_backup_dump_name "$file"
        api_backups_require_target "$name"
        local target; target="$(restore_target "$name")"
        local remote; remote="$(backup_remote_spec)"
        local prefix; prefix="$(backup_dump_prefix "$remote" "$target" "$file")" || api_die not_found "no backup '$file' for '$target'"
        printf '%s' "${remote}/$target/$prefix/$file"
    } 2>"$errf" )"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        local msg; msg="$(grep -E '^\[error\]' "$errf" | tail -n 1 | sed 's/^\[error\] *//' || true)"
        printf '{"api_version":%s,"error":{"code":%s,"message":%s}}\n' "$API_VERSION" \
            "$(json_str "$(cat "$errf.code" 2>/dev/null || echo error)")" "$(json_str "${msg:-backups download failed}")"
        rm -f "$errf" "$errf.code"
        return 1
    fi
    rm -f "$errf" "$errf.code"
    load_conf
    rclone cat "$src"
}
