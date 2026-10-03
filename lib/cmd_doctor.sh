#!/usr/bin/env bash
# `doctor [name]` — health check: nginx/PHP-FPM/database reachability,
# disk space, certificate expiry, one command instead of chasing each of
# those down by hand mid-incident. No name: shared infrastructure plus
# every provisioned site. A name: shared infrastructure plus just that
# one site.

usage_doctor() {
    cat <<'EOF'
usage: ddeploy doctor [-v|--verbose] [--no-notify] [name]

Read-only checks (nginx, PHP-FPM, database reachability, disk space,
certificate expiry, Node toolchain and each site's last frontend
build), printed as [ok]/[warn]/[fail] per line ([off] for a feature
that's disabled on purpose). Without a name, checks the server plus
every provisioned site, one line per site, expanded only where
something needs attention (-v expands every site); with one, the
server plus every check for just that site (previews included).
Exits nonzero if any check failed — fit for cron/monitoring. When
NOTIFY_WEBHOOK is set, a [fail] (not a [warn]) also POSTs there —
unless --no-notify (an interactive check that shouldn't page anyone).
EOF
}

CERT_WARN_DAYS="${CERT_WARN_DAYS:-14}"
DISK_WARN_PERCENT="${DISK_WARN_PERCENT:-85}"

# Prints one result row as TSV: status (ok/warn/fail/off — off is a
# feature disabled on purpose, shown so "silent" and "off" don't look
# alike, but not counted as a pass), check, detail. Site checks leave
# the site's name out of the check column; the section header has it.
# Always to stdout, never accumulated in
# a shared variable, because doctor_check_infra/doctor_check_site run
# inside a command-substitution subshell in cmd_doctor (same reasoning
# as cmd_list.sh's list_row_config: parse_config/resolve_preview_config
# can die() on a malformed config, and a subshell means that only loses
# this one site's/block's remaining checks, not the whole doctor run —
# an array `+=` wouldn't survive that subshell boundary, a printed line
# already captured by the parent's `$(...)` does).
doctor_result() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
}

# $1 cert dir name under /etc/letsencrypt/live (BASE_DOMAIN for the
# shared wildcard, or a custom domain's first FQDN — see
# lib/custom_domain.sh's cert_name), $2 label for the check column.
doctor_check_cert() {
    local certname="$1" label="$2"
    local cert="/etc/letsencrypt/live/$certname/fullchain.pem"
    if [[ ! -f "$cert" ]]; then
        doctor_result fail "$label" "no certificate found at $cert"
        return
    fi
    local enddate; enddate="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)"
    if openssl x509 -checkend $((CERT_WARN_DAYS * 86400)) -noout -in "$cert" >/dev/null 2>&1; then
        doctor_result ok "$label" "valid, expires $enddate"
        return
    fi
    # certbot renews 30 days out, so a cert this close to expiry with the
    # timer running means renewal itself is failing — point at why.
    local why="certbot.timer isn't active — 'systemctl enable --now certbot.timer'"
    systemctl is-active --quiet certbot.timer \
        && why="certbot.timer is active, so renewal is failing — see 'journalctl -u certbot' or 'certbot renew --dry-run'"
    if openssl x509 -checkend 0 -noout -in "$cert" >/dev/null 2>&1; then
        doctor_result warn "$label" "expires within ${CERT_WARN_DAYS}d ($enddate); $why"
    else
        doctor_result fail "$label" "EXPIRED $enddate; $why"
    fi
}

doctor_check_infra() {
    if nginx -t >/dev/null 2>&1; then
        doctor_result ok "nginx config" "valid"
    else
        doctor_result fail "nginx config" "'nginx -t' failed — run it directly for detail"
    fi

    if systemctl is-active --quiet nginx; then
        doctor_result ok "nginx service" "running"
    else
        doctor_result fail "nginx service" "not running"
    fi

    # Root runs code from the checkout (cron, the webhook worker). Whoever
    # can write to any directory above it can rename it away and put their
    # own in its place, root ownership of the checkout itself
    # notwithstanding (docs/security.md).
    local unsafe; unsafe="$(checkout_unsafe_parent)"
    if [[ -n "$unsafe" ]]; then
        doctor_result warn "checkout location" "$unsafe (above $PROVISIONER_DIR) is writable by a non-root user, who could replace the checkout root runs — move it, e.g. to /opt/ddeploy, then re-run init"
    else
        doctor_result ok "checkout location" "$PROVISIONER_DIR, every parent root-owned"
    fi

    local pct; pct="$(df -P / 2>/dev/null | awk 'NR==2 { gsub("%","",$5); print $5 }')"
    if [[ "$pct" =~ ^[0-9]+$ ]]; then
        if [[ "$pct" -ge "$DISK_WARN_PERCENT" ]]; then
            doctor_result warn "disk (/)" "${pct}% used (warn at ${DISK_WARN_PERCENT}%)"
        else
            doctor_result ok "disk (/)" "${pct}% used"
        fi
    else
        doctor_result warn "disk (/)" "couldn't read usage"
    fi

    if db_admin_mysql -e "SELECT 1" >/dev/null 2>&1; then
        doctor_result ok "database server ($DB_HOST)" "reachable"
    else
        doctor_result fail "database server ($DB_HOST)" "admin connection failed — check DB_HOST/DB_ADMIN_CREDENTIALS in provisioner.conf"
    fi

    # Explicit either way, not just when something's wrong — "silent"
    # and "off on purpose" look identical otherwise, and that ambiguity
    # is exactly what prompted adding this.
    if [[ "$WEBHOOK_ENABLED" == "true" ]]; then
        if systemctl is-active --quiet ddeploy-hook; then
            doctor_result ok "webhook listener" "running"
        else
            doctor_result fail "webhook listener" "WEBHOOK_ENABLED=true but ddeploy-hook is not running"
        fi
    else
        doctor_result off "webhook listener" "disabled (WEBHOOK_ENABLED=false)"
    fi

    if [[ "$WEB_ENABLED" == "true" ]]; then
        if [[ ! -f /etc/sudoers.d/ddeploy-web || ! -e /etc/nginx/sites-enabled/ddeploy-web.conf ]]; then
            doctor_result fail "web UI" "WEB_ENABLED=true but its sudoers rule or vhost is missing — run 'ddeploy init-web'"
        elif curl -fsS -m 3 -o /dev/null "http://${WEB_LISTEN}/healthz" 2>/dev/null; then
            doctor_result ok "web UI" "https://$WEB_HOSTNAME (app answering on $WEB_LISTEN)"
        else
            doctor_result warn "web UI" "vhost and sudoers in place, but nothing answers on $WEB_LISTEN — is webddeploy running?"
        fi
    else
        doctor_result off "web UI" "disabled (WEB_ENABLED=false)"
    fi

    doctor_check_node_toolchain

    if [[ "$BACKUP_ENABLED" == "true" ]]; then
        doctor_result ok "uploads backup" "enabled, schedule '$BACKUP_SCHEDULE'"
    else
        doctor_result off "uploads backup" "disabled (BACKUP_ENABLED=false)"
    fi
    if [[ "$DB_BACKUP_ENABLED" == "true" ]]; then
        doctor_result ok "database backup" "enabled, schedule '$DB_BACKUP_SCHEDULE'"
    else
        doctor_result off "database backup" "disabled (DB_BACKUP_ENABLED=false)"
    fi
    if [[ "$PREVIEW_PRUNE_ENABLED" == "true" ]]; then
        doctor_result ok "prune-previews" "enabled, schedule '$PREVIEW_PRUNE_SCHEDULE'"
    else
        doctor_result off "prune-previews" "disabled (PREVIEW_PRUNE_ENABLED=false)"
    fi

    if [[ "$BACKUP_ENABLED" == "true" || "$DB_BACKUP_ENABLED" == "true" || "$PREVIEW_PRUNE_ENABLED" == "true" ]]; then
        if systemctl is-active --quiet cron; then
            doctor_result ok "cron" "running (drives /etc/cron.d/ddeploy-* — not visible in 'crontab -l')"
        else
            doctor_result fail "cron" "backup/prune schedules are written to /etc/cron.d/ but cron itself is not running — re-run 'init'"
        fi
    fi

    # One connectivity check covers both backup types — same bucket,
    # same credentials. Per-site recoverability (dump counts, whether
    # uploads have synced at all) is doctor_check_site's job below; this
    # is just "can we even reach the bucket at all."
    if [[ "$BACKUP_ENABLED" == "true" || "$DB_BACKUP_ENABLED" == "true" ]]; then
        if ! command -v rclone >/dev/null 2>&1; then
            doctor_result fail "object storage" "backup is enabled but rclone is not installed — re-run 'init'"
        elif [[ -z "$BACKUP_CREDENTIALS" || ! -f "$BACKUP_CREDENTIALS" || -z "$BACKUP_BUCKET" ]]; then
            doctor_result fail "object storage" "BACKUP_CREDENTIALS (provisioner.conf) or BACKUP_BUCKET (in that file) not set"
        else
            if [[ -n "${BACKUP_BUCKET_CONF:-}" && "$BACKUP_BUCKET_CONF" != "$BACKUP_BUCKET" ]]; then
                doctor_result warn "object storage" "BACKUP_BUCKET is '$BACKUP_BUCKET' in $BACKUP_CREDENTIALS (used) but '$BACKUP_BUCKET_CONF' in provisioner.conf (ignored) — remove the one in provisioner.conf"
            fi
            local remote; remote="$(backup_remote_spec)"
            local fixed
            if fixed="$(backup_endpoint_with_bucket "$(backup_endpoint)" "$BACKUP_BUCKET")"; then
                doctor_result fail "object storage ($BACKUP_BUCKET)" "BACKUP_ENDPOINT includes the bucket name, so backups are filed under $BACKUP_BUCKET/$BACKUP_BUCKET/ and can't be found or restored — set BACKUP_ENDPOINT=\"$fixed\" in $BACKUP_CREDENTIALS, then move what's there: rclone move $remote/$BACKUP_BUCKET $remote"
            elif timeout 15 rclone lsd "$remote" >/dev/null 2>&1; then
                doctor_result ok "object storage ($BACKUP_BUCKET)" "reachable"
            else
                doctor_result fail "object storage ($BACKUP_BUCKET)" "could not list the bucket with the configured credentials"
            fi
        fi
    fi

    doctor_check_cert "$BASE_DOMAIN" "cert (wildcard, $BASE_DOMAIN)"

    if systemctl is-active --quiet certbot.timer; then
        doctor_result ok "certbot.timer" "active (handles renewal)"
    else
        doctor_result warn "certbot.timer" "not active — certificates won't auto-renew"
    fi
}

# nvm at the pinned commit, and every BASELINE_NODE spec installed.
doctor_check_node_toolchain() {
    if [[ "$NODE_ENABLED" != "true" ]]; then
        doctor_result off "node (nvm)" "disabled (NODE_ENABLED=false)"
        return
    fi
    if [[ ! -f "$NVM_ROOT/nvm.sh" ]]; then
        doctor_result fail "node (nvm)" "nvm not installed at $NVM_ROOT — re-run 'init'"
        return
    fi
    local head; head="$(git -C "$NVM_ROOT" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$head" != "$NVM_COMMIT" ]]; then
        doctor_result fail "node (nvm)" "$NVM_ROOT is at '${head:-?}', expected $NVM_TAG ($NVM_COMMIT) — re-run 'init'"
        return
    fi
    local installed
    installed="$(find "$NVM_ROOT/versions/node" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | paste -sd' ')"
    doctor_result ok "node (nvm $NVM_TAG)" "installed: ${installed:-none}"
    local spec ver
    for spec in $BASELINE_NODE; do
        ver="$(nvm_cmd version "$spec" 2>/dev/null || true)"
        [[ "$ver" == v* ]] || doctor_result warn "node $spec" "in BASELINE_NODE but not installed — re-run 'init'"
    done
}

# Seconds -> "3m" / "5h" / "2d".
doctor_age() {
    local s="$1"
    if (( s < 3600 )); then echo "$((s / 60))m"
    elif (( s < 172800 )); then echo "$((s / 3600))h"
    else echo "$((s / 86400))d"
    fi
}

# $1 site name, already resolved via parse_config. Resolved Node version,
# and the last build's result (lib/node.sh's record_build_state).
doctor_check_site_node() {
    local name="$1"
    [[ "$NODE_ENABLED" == "true" && -n "${NODE_VERSION_SPEC:-}" ]] || return 0
    local needs=0
    [[ "$BUILD_ENABLED" == "true" || "$NODE_VERSION_SOURCE" != "default" ]] && needs=1

    local ver; ver="$(nvm_cmd version "$NODE_VERSION_SPEC" 2>/dev/null || true)"
    if [[ "$ver" == v* ]]; then
        [[ "$needs" -eq 1 ]] && doctor_result ok "node" "$ver ($NODE_VERSION_SPEC, from $NODE_VERSION_SOURCE)"
    elif [[ "$needs" -eq 1 ]]; then
        doctor_result warn "node" "$NODE_VERSION_SPEC (from $NODE_VERSION_SOURCE) isn't installed yet — the next deploy installs it"
    fi

    [[ "$BUILD_ENABLED" == "true" ]] || return 0
    local f; f="$(build_state_path "$name")"
    if [[ ! -s "$f" ]]; then
        doctor_result warn "frontend build" "enabled, but no build recorded yet"
        return
    fi
    local status ts bver detail age
    IFS=$'\t' read -r status ts bver detail < "$f"
    age="$(doctor_age $(( $(date +%s) - ${ts:-0} )))"
    if [[ "$status" == "ok" ]]; then
        doctor_result ok "frontend build" "built $age ago, node $bver ($detail)"
    else
        doctor_result warn "frontend build" "LAST BUILD FAILED $age ago ($detail) — the live release is from an earlier deploy; see 'logs $name'"
    fi
}

# $1 site name (already resolved to config — DB_BACKUP_ENABLED,
# BACKUP_CREDENTIALS etc. are globals from load_conf, not per-site).
# Reports how many dump backups this site actually has, and how old the
# newest one is — "is backup-database configured" is doctor_check_infra's
# job; this is "has it actually produced anything recoverable."
doctor_check_db_backup() {
    local name="$1"
    command -v rclone >/dev/null 2>&1 || return 0
    [[ -n "$BACKUP_CREDENTIALS" && -f "$BACKUP_CREDENTIALS" && -n "$BACKUP_BUCKET" ]] || return 0

    local remote; remote="$(backup_remote_spec)"
    local target; target="$(restore_target "$name")"
    # No `timeout` wrapper here — list_database_backups is a shell
    # function, not an executable, and `timeout <name>` silently fails
    # to find it as a command (confirmed: this returned "no dumps"
    # every time in testing, even against a bucket with real dumps in
    # it, until this was caught). Matches how the same function is
    # already called, un-timed-out, everywhere else it's used.
    # rclone's own error is reported, not read as "no dumps": a listing
    # that failed (credentials, endpoint, timeout) isn't an empty bucket.
    local raw rc=0 dumps
    raw="$(rclone lsf "${remote}/$target/db/" 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 && "$raw" != *"directory not found"* ]]; then
        local why; why="$(grep -E 'ERROR|Failed' <<< "$raw" | tail -n 1 || true)"
        [[ -n "$why" ]] || why="$(grep -v '^[[:space:]]*$' <<< "$raw" | tail -n 1 || true)"
        doctor_result warn "database backups" "couldn't list $BACKUP_BUCKET/$target/db/: ${why:0:200}"
        return
    fi
    [[ "$rc" -eq 0 ]] || raw=""
    dumps="$(grep -E '\.sql(\.gz)?$' <<< "$raw" | sort -r || true)"
    local count=0
    [[ -n "$dumps" ]] && count="$(grep -c . <<< "$dumps")"

    if [[ "$count" -eq 0 ]]; then
        doctor_result warn "database backups" "0 recoverable dumps in $BACKUP_BUCKET/$target/db/ — has backup-database run yet?"
        return
    fi

    # Filenames encode <db>-YYYYMMDD-HHMMSS.sql.gz (db_backup.sh); parse
    # the newest one's timestamp to report its age, not just its count.
    # Reported as fact, not judged against a threshold — DB_BACKUP_SCHEDULE
    # is an arbitrary cron expression (hourly by default, but could just
    # as validly be daily/weekly), and doctor has no reliable way to
    # derive "how old is too old" from that without a real cron-expression
    # parser; guessing a fixed threshold would just false-warn anyone not
    # on the default schedule.
    local newest ts age_desc epoch
    newest="$(head -n1 <<< "$dumps")"
    ts="$(grep -oE '[0-9]{8}-[0-9]{6}' <<< "$newest" | head -1)"
    age_desc="age unknown"
    if [[ -n "$ts" ]]; then
        epoch="$(date -u -d "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2}" +%s 2>/dev/null || echo 0)"
        if [[ "$epoch" -gt 0 ]]; then
            age_desc="newest is $(( ($(date -u +%s) - epoch) / 3600 ))h old"
        fi
    fi
    doctor_result ok "database backups" "$count recoverable dump(s), $age_desc"
}

# $1 site name — a weaker signal than the database check above: this is
# a live mirror, not a dated series, so a remote file's timestamp
# doesn't reliably indicate staleness (nothing changing locally also
# means nothing changing remotely, even with sync working perfectly).
# Checkable: the last backup-uploads run's outcome, and that a folder
# with files locally has synced content. Empty folders have nothing to
# back up, so they aren't "not backed up yet".
doctor_check_uploads_backup() {
    local name="$1"
    command -v rclone >/dev/null 2>&1 || return 0
    [[ -n "$BACKUP_CREDENTIALS" && -f "$BACKUP_CREDENTIALS" && -n "$BACKUP_BUCKET" ]] || return 0
    [[ "${#UPLOAD_DIRS[@]}" -gt 0 ]] || return 0

    local target; target="$(restore_target "$name")"
    local last=""
    [[ -f "$EVENTS_DIR/$target.jsonl" ]] \
        && last="$(grep -E '"kind":"backup-uploads","phase":"(succeeded|failed)"' "$EVENTS_DIR/$target.jsonl" | tail -n 1 || true)"
    if [[ "$last" == *'"phase":"failed"'* ]]; then
        local why; why="$(sed -nE 's/.*"error":"([^"]*)".*/\1/p' <<< "$last")"
        doctor_result warn "uploads backup" "the last files backup failed${why:+: ${why:0:200}}"
        return
    fi

    # The first upload dir with files in it; none: nothing to back up.
    local d dir="" with_files=0
    for d in "${UPLOAD_DIRS[@]}"; do
        if [[ -n "$(find "$PERSISTENT_ROOT/$target/$d" -type f -print -quit 2>/dev/null)" ]]; then
            with_files=$((with_files + 1))
            [[ -n "$dir" ]] || dir="$d"
        fi
    done
    if [[ -z "$dir" ]]; then
        doctor_result ok "uploads backup" "upload folders are empty — nothing to back up yet"
        return
    fi
    local suffix=""
    [[ "$with_files" -gt 1 ]] && suffix=" (checked 1 of $with_files folders with files)"

    local remote; remote="$(backup_remote_spec)"
    # lsf doesn't recurse: one level of a large uploads folder, not all of it.
    local raw rc=0
    raw="$(timeout 30 rclone lsf "${remote}/${target}/${dir}/" 2>&1)" || rc=$?
    if [[ "$rc" -eq 0 ]] && grep -qv '^[[:space:]]*$' <<< "$raw" && ! grep -q 'ERROR' <<< "$raw"; then
        doctor_result ok "uploads backup" "'$dir' has synced content$suffix"
    elif [[ "$rc" -eq 124 ]]; then
        doctor_result warn "uploads backup" "listing $BACKUP_BUCKET/$target/$dir/ timed out after 30s$suffix"
    elif grep -q 'ERROR\|Failed' <<< "$raw" && ! grep -q 'directory not found' <<< "$raw"; then
        doctor_result warn "uploads backup" "couldn't list $BACKUP_BUCKET/$target/$dir/: $(grep 'ERROR\|Failed' <<< "$raw" | tail -n 1 | cut -c1-200)$suffix"
    else
        doctor_result warn "uploads backup" "'$dir' has files but none in $BACKUP_BUCKET/$target/$dir/ yet — has backup-uploads run yet?$suffix"
    fi
}

# Does the site actually answer? A GET of / through this server's own
# nginx (--resolve to 127.0.0.1, so DNS and any CDN in front don't
# matter). 2xx/3xx, and 401 from basic auth, mean PHP served it; 5xx or
# no answer is a failure the vhost/FPM/database checks alone can miss.
doctor_check_site_http() {
    local name="$1" host="$1.$BASE_DOMAIN" out code secs
    command -v curl >/dev/null 2>&1 || return 0
    out="$(curl -sk -o /dev/null -m 10 -w '%{http_code} %{time_total}' --resolve "$host:443:127.0.0.1" "https://$host/" 2>/dev/null || true)"
    code="${out%% *}"
    secs="${out#* }"
    local ms; ms="$(awk -v s="${secs:-0}" 'BEGIN { printf "%d", s * 1000 }')"
    case "$code" in
        2??|3??) doctor_result ok "http" "GET / -> $code in ${ms}ms" ;;
        401)     doctor_result ok "http" "GET / -> 401 (basic auth) in ${ms}ms" ;;
        4??)     doctor_result warn "http" "GET / -> $code in ${ms}ms" ;;
        5??)     doctor_result fail "http" "GET / -> $code — the app is erroring (see 'ddeploy logs $name' and the PHP-FPM log)" ;;
        *)       doctor_result fail "http" "no response from https://$host/ within 10s" ;;
    esac
}

doctor_check_site() {
    local name="$1"
    local dir; dir="$(site_dir "$name")"

    if is_preview "$name"; then
        read_preview_meta "$name" || { doctor_result fail "config" "preview metadata unreadable"; return; }
        resolve_preview_config "$name" "$PREVIEW_PROJECT" "$PREVIEW_MODE"
    else
        local cfg_path; cfg_path="$(resolve_config_path "$name")"
        if [[ -z "$cfg_path" ]]; then
            doctor_result fail "config" "no config found (.ddev/config.yaml or sidecar)"
            return
        fi
        parse_config "$name" "$cfg_path" 0
    fi

    if [[ -f "/etc/nginx/sites-enabled/$name.conf" ]]; then
        doctor_result ok "vhost" "enabled"
    else
        doctor_result fail "vhost" "not enabled"
    fi

    if systemctl is-active --quiet "php${PHP_VERSION}-fpm"; then
        doctor_result ok "php${PHP_VERSION}-fpm" "running"
    else
        doctor_result fail "php${PHP_VERSION}-fpm" "not running"
    fi

    if [[ -d "$dir/.git" ]]; then
        local sha when branch
        sha="$(git -C "$dir" log -1 --format=%h 2>/dev/null || echo '?')"
        when="$(git -C "$dir" log -1 --format=%cd --date=short 2>/dev/null || echo '?')"
        branch="$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || echo 'detached')"
        doctor_result ok "last deploy" "$branch @ $sha ($when)"
    fi

    doctor_check_site_node "$name"
    doctor_check_site_http "$name"

    # As the site's OWN user/credentials, not the admin connection
    # doctor_check_infra already tested — this catches a revoked grant
    # or a credential file that's drifted from what the DB actually has,
    # not just "is the server up."
    local pass; pass="$(read_db_password "$name" "$dir" "$DB_ENV_SCHEME")"
    if [[ -z "$pass" ]]; then
        doctor_result warn "database" "no credentials on file yet (re-run provision?)"
    elif mysql_as_user "$DB_USER" "$pass" -h "$DB_HOST" "$DB_NAME" -e "SELECT 1" >/dev/null 2>&1; then
        doctor_result ok "database" "reachable as '$DB_USER'"
    else
        doctor_result fail "database" "connection failed as '$DB_USER'@'$DB_HOST' — credentials may be stale"
    fi

    if [[ "${#ADDITIONAL_FQDNS[@]}" -gt 0 ]]; then
        doctor_check_cert "${ADDITIONAL_FQDNS[0]}" "cert (custom domain)"
    fi

    # Skipped for a shared-mode preview: its uploads/database ARE its
    # parent's, not its own — already covered by the parent's own row,
    # same skip cmd_backup.sh/cmd_db_backup.sh themselves already apply.
    if ! { is_preview "$name" && [[ "$PREVIEW_MODE" == "shared" ]]; }; then
        [[ "$DB_BACKUP_ENABLED" == "true" ]] && doctor_check_db_backup "$name"
        [[ "$BACKUP_ENABLED" == "true" ]] && doctor_check_uploads_backup "$name"
    fi
}

# Sets the DOCTOR_C_* escapes: colored on a terminal, plain when piped
# or captured (cron mail, monitoring, the test suite) or with NO_COLOR.
doctor_colors() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        DOCTOR_C_ok=$'\033[32m' DOCTOR_C_warn=$'\033[33m' DOCTOR_C_fail=$'\033[31m'
        DOCTOR_C_off=$'\033[2m' DOCTOR_C_bold=$'\033[1m' DOCTOR_C_reset=$'\033[0m'
    else
        DOCTOR_C_ok="" DOCTOR_C_warn="" DOCTOR_C_fail="" DOCTOR_C_off="" DOCTOR_C_bold="" DOCTOR_C_reset=""
    fi
}

# "  [warn] " — the tag padded to a fixed width before coloring, so the
# escapes don't throw the columns off.
doctor_tag() {
    local status="$1" c="DOCTOR_C_$1"
    printf '%s%-6s%s ' "${!c}" "[$status]" "$DOCTOR_C_reset"
}

# The worst status among TSV rows $1: fail > warn > ok.
doctor_worst() {
    local rows="$1"
    if grep -q $'^fail\t' <<< "$rows"; then echo fail
    elif grep -q $'^warn\t' <<< "$rows"; then echo warn
    else echo ok
    fi
}

# Prints TSV rows $1 indented by $2 spaces, check names padded to the
# widest in this block. $3=1 prints only warn/fail rows.
doctor_print_rows() {
    local rows="$1" indent="$2" problems_only="${3:-0}"
    local width=0 status check detail
    while IFS=$'\t' read -r status check detail; do
        [[ -n "$status" ]] && (( ${#check} > width )) && width=${#check}
    done <<< "$rows"
    while IFS=$'\t' read -r status check detail; do
        [[ -z "$status" ]] && continue
        [[ "$problems_only" == "1" && "$status" != warn && "$status" != fail ]] && continue
        printf '%*s%s%-*s  %s\n' "$indent" '' "$(doctor_tag "$status")" "$width" "$check" "$detail"
    done <<< "$rows"
}

cmd_doctor() {
    local verbose=0 only="" no_notify=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)    usage_doctor; return 0 ;;
            -v|--verbose) verbose=1; shift ;;
            --no-notify)  no_notify=1; shift ;;
            -*)           die "unknown option '$1' (see 'doctor -h')" ;;
            *)            [[ -z "$only" ]] || die "doctor takes at most one site name"; only="$1"; shift ;;
        esac
    done
    load_conf
    require_root

    if [[ -n "$only" ]]; then
        validate_name "$only"
        is_provisioned "$only" || die "'$only' is not provisioned"
    fi
    doctor_colors
    PARSE_CONFIG_QUIET=1

    local all="" block
    block="$(doctor_check_infra)" || block+=$'\n'"fail"$'\t'"infra"$'\t'"infra checks crashed unexpectedly — see stderr above"
    all+="$block"$'\n'
    printf '%sServer%s\n' "$DOCTOR_C_bold" "$DOCTOR_C_reset"
    doctor_print_rows "$block" 2

    local -a names=()
    local name
    if [[ -n "$only" ]]; then
        names=("$only")
    else
        local site_path
        # No trailing slash on the glob: "foo/" sorts after "foo-bar/"
        # ('-' < '/'), which would list a site's previews before it.
        for site_path in "$SITES_ROOT"/*; do
            [[ -d "$site_path" ]] || continue
            name="$(basename "$site_path")"
            is_provisioned "$name" && names+=("$name")
        done
    fi

    # One line per site: worst status, name, and what's deployed (the
    # "last deploy" row) — then its rows underneath. A single named site
    # or -v shows every row; the fleet view only the ones needing a look,
    # so 20 healthy sites are 20 lines, not 150.
    [[ "${#names[@]}" -gt 0 ]] && printf '\n%sSites%s\n' "$DOCTOR_C_bold" "$DOCTOR_C_reset"
    local width=0 n
    for n in "${names[@]}"; do (( ${#n} > width )) && width=${#n}; done
    for name in "${names[@]}"; do
        block="$(doctor_check_site "$name")" || block+=$'\n'"fail"$'\t'"check"$'\t'"crashed unexpectedly — see stderr above"
        all+="$block"$'\n'
        local worst summary label="$name"
        worst="$(doctor_worst "$block")"
        summary="$(awk -F'\t' '$2 == "last deploy" { print $3; exit }' <<< "$block")"
        is_preview "$name" && read_preview_meta "$name" 2>/dev/null \
            && summary="${summary:+$summary  }(preview of $PREVIEW_PROJECT, $PREVIEW_MODE)"
        printf '  %s%s%-*s%s  %s\n' "$(doctor_tag "$worst")" "$DOCTOR_C_bold" "$width" "$label" "$DOCTOR_C_reset" "$summary"
        if [[ -n "$only" || "$verbose" == "1" ]]; then
            doctor_print_rows "$(grep -v $'\tlast deploy\t' <<< "$block")" 9
        elif [[ "$worst" != ok ]]; then
            doctor_print_rows "$block" 9 1
        fi
    done

    local ok fail warn off
    ok="$(grep -c $'^ok\t' <<< "$all" || true)"
    warn="$(grep -c $'^warn\t' <<< "$all" || true)"
    fail="$(grep -c $'^fail\t' <<< "$all" || true)"
    off="$(grep -c $'^off\t' <<< "$all" || true)"
    local tally="$ok ok, $warn warn, $fail fail, $off off"
    echo
    if [[ "$fail" -gt 0 ]]; then
        log_error "doctor: $tally"
        [[ "$no_notify" -eq 1 ]] || notify_failure doctor "${only:-}" "$fail fail, $warn warn"
    elif [[ "$warn" -gt 0 ]]; then
        log_warn "doctor: $tally"
    else
        log_info "doctor: $tally"
    fi
    [[ "$fail" -eq 0 ]]
}
