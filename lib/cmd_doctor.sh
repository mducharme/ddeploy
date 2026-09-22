#!/usr/bin/env bash
# `doctor [name]` — health check: nginx/PHP-FPM/database reachability,
# disk space, certificate expiry, one command instead of chasing each of
# those down by hand mid-incident. No name: shared infrastructure plus
# every provisioned site. A name: shared infrastructure plus just that
# one site.

usage_doctor() {
    cat <<'EOF'
usage: provision.sh doctor [name]

Read-only checks (nginx, PHP-FPM, database reachability, disk space,
certificate expiry), printed as [ok]/[warn]/[fail] per line. Without a
name, checks shared infrastructure plus every provisioned site; with
one, shared infrastructure plus just that site (previews included).
Exits nonzero if any check failed — fit for cron/monitoring. When
NOTIFY_WEBHOOK is set, a [fail] (not a [warn]) also POSTs there.
EOF
}

CERT_WARN_DAYS="${CERT_WARN_DAYS:-14}"
DISK_WARN_PERCENT="${DISK_WARN_PERCENT:-85}"

# Prints one result row as TSV — always to stdout, never accumulated in
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
    else
        doctor_result warn "$label" "expires within ${CERT_WARN_DAYS}d ($enddate) — certbot.timer should renew automatically; verify it's running"
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
        doctor_result ok "webhook listener" "disabled (WEBHOOK_ENABLED=false)"
    fi

    if [[ "$BACKUP_ENABLED" == "true" ]]; then
        doctor_result ok "uploads backup" "enabled, schedule '$BACKUP_SCHEDULE'"
    else
        doctor_result ok "uploads backup" "disabled (BACKUP_ENABLED=false)"
    fi
    if [[ "$DB_BACKUP_ENABLED" == "true" ]]; then
        doctor_result ok "database backup" "enabled, schedule '$DB_BACKUP_SCHEDULE'"
    else
        doctor_result ok "database backup" "disabled (DB_BACKUP_ENABLED=false)"
    fi
    if [[ "$PREVIEW_PRUNE_ENABLED" == "true" ]]; then
        doctor_result ok "prune-previews" "enabled, schedule '$PREVIEW_PRUNE_SCHEDULE'"
    else
        doctor_result ok "prune-previews" "disabled (PREVIEW_PRUNE_ENABLED=false)"
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
            doctor_result fail "object storage" "BACKUP_CREDENTIALS/BACKUP_BUCKET not fully set in provisioner.conf"
        else
            local remote; remote="$(backup_remote_spec)"
            if timeout 15 rclone lsd "$remote" >/dev/null 2>&1; then
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

# $1 site name, already known to be provisioned.
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
    local dumps; dumps="$(list_database_backups "$target" "$remote" 2>/dev/null)"
    local count=0
    [[ -n "$dumps" ]] && count="$(grep -c . <<< "$dumps")"

    if [[ "$count" -eq 0 ]]; then
        doctor_result warn "$name: database backups" "0 recoverable dumps in $BACKUP_BUCKET/$target/db/ — has backup-database run yet?"
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
    doctor_result ok "$name: database backups" "$count recoverable dump(s), $age_desc"
}

# $1 site name — a weaker signal than the database check above: this is
# a live mirror, not a dated series, so a remote file's timestamp
# doesn't reliably indicate staleness (nothing changing locally also
# means nothing changing remotely, even with sync working perfectly).
# "has anything ever synced at all" is what's actually checkable here.
doctor_check_uploads_backup() {
    local name="$1"
    command -v rclone >/dev/null 2>&1 || return 0
    [[ -n "$BACKUP_CREDENTIALS" && -f "$BACKUP_CREDENTIALS" && -n "$BACKUP_BUCKET" ]] || return 0
    [[ "${#UPLOAD_DIRS[@]}" -gt 0 ]] || return 0

    local remote; remote="$(backup_remote_spec)"
    local target; target="$(restore_target "$name")"
    local dir="${UPLOAD_DIRS[0]}"
    local suffix=""
    [[ "${#UPLOAD_DIRS[@]}" -gt 1 ]] && suffix=" (checked 1 of ${#UPLOAD_DIRS[@]} upload_dirs)"

    if timeout 15 rclone lsf "${remote}/${target}/${dir}/" 2>/dev/null | grep -q .; then
        doctor_result ok "$name: uploads backup" "'$dir' has synced content$suffix"
    else
        doctor_result warn "$name: uploads backup" "'$dir' has no synced content in $BACKUP_BUCKET/$target/$dir/ yet — has backup-uploads run yet?$suffix"
    fi
}

doctor_check_site() {
    local name="$1"
    local dir; dir="$(site_dir "$name")"

    if is_preview "$name"; then
        read_preview_meta "$name" || { doctor_result fail "$name" "preview metadata unreadable"; return; }
        resolve_preview_config "$name" "$PREVIEW_PROJECT" "$PREVIEW_MODE"
    else
        local cfg_path; cfg_path="$(resolve_config_path "$name")"
        if [[ -z "$cfg_path" ]]; then
            doctor_result fail "$name" "no config found (.ddev/config.yaml or sidecar)"
            return
        fi
        parse_config "$name" "$cfg_path" 0
    fi

    if [[ -f "/etc/nginx/sites-enabled/$name.conf" ]]; then
        doctor_result ok "$name: vhost" "enabled"
    else
        doctor_result fail "$name: vhost" "not enabled"
    fi

    if systemctl is-active --quiet "php${PHP_VERSION}-fpm"; then
        doctor_result ok "$name: php${PHP_VERSION}-fpm" "running"
    else
        doctor_result fail "$name: php${PHP_VERSION}-fpm" "not running"
    fi

    if [[ -d "$dir/.git" ]]; then
        local sha when
        sha="$(git -C "$dir" log -1 --format=%h 2>/dev/null || echo '?')"
        when="$(git -C "$dir" log -1 --format=%cd --date=short 2>/dev/null || echo '?')"
        doctor_result ok "$name: last deploy" "$sha ($when)"
    fi

    # As the site's OWN user/credentials, not the admin connection
    # doctor_check_infra already tested — this catches a revoked grant
    # or a credential file that's drifted from what the DB actually has,
    # not just "is the server up."
    local pass; pass="$(read_db_password "$name" "$dir" "$DB_ENV_SCHEME")"
    if [[ -z "$pass" ]]; then
        doctor_result warn "$name: database" "no credentials on file yet (re-run provision?)"
    elif MYSQL_PWD="$pass" mysql -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "SELECT 1" >/dev/null 2>&1; then
        doctor_result ok "$name: database" "reachable as '$DB_USER'"
    else
        doctor_result fail "$name: database" "connection failed as '$DB_USER'@'$DB_HOST' — credentials may be stale"
    fi

    if [[ "${#ADDITIONAL_FQDNS[@]}" -gt 0 ]]; then
        doctor_check_cert "${ADDITIONAL_FQDNS[0]}" "$name: cert (custom domain)"
    fi

    # Skipped for a shared-mode preview: its uploads/database ARE its
    # parent's, not its own — already covered by the parent's own row,
    # same skip cmd_backup.sh/cmd_db_backup.sh themselves already apply.
    if ! { is_preview "$name" && [[ "$PREVIEW_MODE" == "shared" ]]; }; then
        [[ "$DB_BACKUP_ENABLED" == "true" ]] && doctor_check_db_backup "$name"
        [[ "$BACKUP_ENABLED" == "true" ]] && doctor_check_uploads_backup "$name"
    fi
}

cmd_doctor() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_doctor; return 0; }
    load_conf
    require_root

    local only="${1:-}"
    if [[ -n "$only" ]]; then
        validate_name "$only"
        is_provisioned "$only" || die "'$only' is not provisioned"
    fi

    local all="" block
    block="$(doctor_check_infra)" || block="fail"$'\t'"infra"$'\t'"infra checks crashed unexpectedly — see stderr above"
    all+="$block"$'\n'

    if [[ -n "$only" ]]; then
        block="$(doctor_check_site "$only")" || block="fail"$'\t'"$only"$'\t'"check crashed unexpectedly — see stderr above"
        all+="$block"$'\n'
    else
        local site_path name
        for site_path in "$SITES_ROOT"/*/; do
            [[ -d "$site_path" ]] || continue
            name="$(basename "$site_path")"
            is_provisioned "$name" || continue
            block="$(doctor_check_site "$name")" || block="fail"$'\t'"$name"$'\t'"check crashed unexpectedly — see stderr above"
            all+="$block"$'\n'
        done
    fi

    local ok=0 warn=0 fail=0 status check detail
    while IFS=$'\t' read -r status check detail; do
        [[ -z "$status" ]] && continue
        case "$status" in
            ok)   ok=$((ok + 1));   printf '  [ok]   %-34s %s\n' "$check" "$detail" ;;
            warn) warn=$((warn + 1)); printf '  [warn] %-34s %s\n' "$check" "$detail" ;;
            fail) fail=$((fail + 1)); printf '  [fail] %-34s %s\n' "$check" "$detail" ;;
        esac
    done <<< "$all"

    log_info "doctor: $ok ok, $warn warn, $fail fail"
    if [[ "$fail" -gt 0 ]]; then
        notify_failure doctor "${only:-}" "$fail fail, $warn warn"
    fi
    [[ "$fail" -eq 0 ]]
}
