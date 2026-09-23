#!/usr/bin/env bash
# One MariaDB/MySQL server (local or remote, see db_admin_mysql); one
# database + user per site, scoped to only that database. `database:` in
# the site's config is informational only — never branched on for
# engine/version.
#
# Which credential file/format gets written IS branched on, via
# DB_ENV_SCHEME (set by config.sh, from CMS detection or an explicit
# db_env_scheme: field):
#   laravel  - .env: DB_HOST/DB_DATABASE/DB_USERNAME/DB_PASSWORD
#   craft    - .env: CRAFT_DB_*
#   charcoal - config/config.local.json: databases.<default_database>.*
#   none     - CMS doesn't read DB config from .env at all (plain
#              WordPress) — credentials saved to a root-only file instead
#              so re-runs stay idempotent, and logged once for manual entry.

# Runs an admin-level mysql command (CREATE/DROP DATABASE/USER). Uses
# local, credential-less unix-socket root when DB_HOST is local and no
# admin credentials are configured (the default, zero-config case);
# otherwise connects over TCP with DB_ADMIN_CREDENTIALS, a MySQL
# option-file (`[client]\nuser=...\npassword=...`).
db_admin_mysql() {
    if [[ ( "$DB_HOST" == "127.0.0.1" || "$DB_HOST" == "localhost" ) && -z "$DB_ADMIN_CREDENTIALS" ]]; then
        mysql "$@"
    else
        [[ -n "$DB_ADMIN_CREDENTIALS" ]] || die "DB_HOST ($DB_HOST) is remote but DB_ADMIN_CREDENTIALS is not set in provisioner.conf"
        [[ -f "$DB_ADMIN_CREDENTIALS" ]] || die "DB_ADMIN_CREDENTIALS file not found: $DB_ADMIN_CREDENTIALS"
        mysql --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" "$@"
    fi
}

# Reads a scalar from a JSON file via yq. Unlike a YAML-sourced file
# (where plain-mode yq strips quotes automatically), yq's plain-mode
# output for a JSON-sourced file keeps the surrounding quotes — strip one
# matching pair here so callers get a bare value either way. Empty,
# missing, or null all report as "not found" (nonzero exit).
json_read() {
    local file="$1" path="$2" val
    [[ -f "$file" ]] || return 1
    val="$(yq eval "$path" "$file" 2>/dev/null)"
    [[ "$val" == "null" || -z "$val" ]] && return 1
    if [[ "${val:0:1}" == '"' && "${val: -1}" == '"' ]]; then
        val="${val:1:-1}"
    fi
    printf '%s' "$val"
}

# Sets a scalar in a JSON file via yq, creating the file (as `{}`) if
# needed. -o=json on the in-place edit keeps the file valid JSON (yq's
# default in-place output is YAML, which would break a JSON consumer).
# Escapes backslashes/quotes in val before interpolating it into the yq
# expression — belt-and-suspenders alongside json_read's unquoting, since
# db_name/db_user are already charset-validated but a value read back
# from disk (e.g. a hand-edited config.local.json) shouldn't be trusted
# to be injection-safe.
json_write() {
    local file="$1" path="$2" val="$3"
    [[ -f "$file" ]] || printf '{}\n' > "$file"
    val="${val//\\/\\\\}"
    val="${val//\"/\\\"}"
    yq eval -i -o=json "${path} = \"${val}\"" "$file"
}

# Escapes a value for safe interpolation into a single-quoted MySQL/
# MariaDB string literal. Doubles single quotes (ANSI-SQL) AND backslashes
# (MariaDB's default sql_mode still treats \ as an escape inside strings,
# so a password containing \ or \'; would otherwise break out). Newlines
# cannot be quoted away in a heredoc statement — refuse them. Used for
# db_pass in db_ensure: unlike db_name/db_user (validate_db_identifier),
# a password is opaque and may have been read back from a client-editable
# .env (read_db_password).
sql_quote() {
    local s="$1"
    [[ "$s" != *$'\n'* && "$s" != *$'\r'* ]] \
        || die "database password contains a newline — refusing to interpolate it into SQL"
    s="${s//\\/\\\\}"
    s="${s//\'/\'\'}"
    printf '%s' "$s"
}

# Charcoal's active DB entry is named by default_database (usually
# "default", but not always — e.g. a project keyed "mysql" alongside a
# "sqlite" fallback). Reads it back if the file already names one, else
# "default"; constrained to a safe identifier charset before it's ever
# interpolated into a yq path expression.
charcoal_db_key() {
    local charcoal_json="$1" key
    key="$(json_read "$charcoal_json" '.default_database' || true)"
    if [[ "$key" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo "$key"
    else
        echo "default"
    fi
}

# Reads a site's existing DB password back out of wherever $scheme
# stores it. Empty if none is on file yet. $1 name, $2 site dir, $3 scheme.
read_db_password() {
    local name="$1" dir="$2" scheme="$3"
    case "$scheme" in
        craft)    read_env_var "$dir/.env" CRAFT_DB_PASSWORD || true ;;
        none)
            if [[ -f "$GENERATED_DIR/$name.dbpass" ]]; then
                cat "$GENERATED_DIR/$name.dbpass"
            fi
            ;;
        charcoal)
            local cj="$dir/config/config.local.json"
            json_read "$cj" ".databases.$(charcoal_db_key "$cj").password" || true
            ;;
        *)        read_env_var "$dir/.env" DB_PASSWORD || true ;;
    esac
}

# Writes db_name/db_user/db_pass into $dir in whichever format $scheme
# calls for — the read/write counterpart to read_db_password, and the
# part of db_ensure that's still needed when the database itself already
# exists elsewhere (a shared-mode preview linking to its parent's DB
# rather than creating its own — see lib/preview.sh).
# $7 (optional) owner — defaults to the site's own www-<name>. A
# shared-mode preview passes its parent's user instead: PHP-FPM for that
# preview runs as the parent's user (see lib/vhost.sh apply_permissions),
# which needs to be the one able to read this file, not a www-<name>
# that — in shared mode — is never even created.
write_db_credentials() {
    local name="$1" dir="$2" db_name="$3" db_user="$4" db_pass="$5" scheme="$6"
    local owner="${7:-www-$name}"
    case "$scheme" in
        craft)
            # Pre-create at 600 before the writes below — write_env_var's
            # own `touch` would otherwise briefly create it at the
            # process umask's default (commonly world-readable) for the
            # few milliseconds until the chmod at the end of this case.
            touch "$dir/.env" && chmod 600 "$dir/.env"
            write_env_var "$dir/.env" CRAFT_DB_DRIVER "mysql"
            write_env_var "$dir/.env" CRAFT_DB_SERVER "$DB_HOST"
            write_env_var "$dir/.env" CRAFT_DB_DATABASE "$db_name"
            write_env_var "$dir/.env" CRAFT_DB_USER "$db_user"
            write_env_var "$dir/.env" CRAFT_DB_PASSWORD "$db_pass"
            chown "$owner:www-data" "$dir/.env"
            # 600, not 640 — nginx (www-data, the group here) never opens
            # this file itself; only PHP-FPM, running as $owner, does. See
            # apply_permissions (lib/vhost.sh) for why this stays 600
            # across every later deploy too, not just this write.
            chmod 600 "$dir/.env"
            ;;
        none)
            mkdir -p "$GENERATED_DIR"
            printf '%s' "$db_pass" > "$GENERATED_DIR/$name.dbpass"
            chmod 600 "$GENERATED_DIR/$name.dbpass"
            log_warn "db_env_scheme=none — this CMS doesn't read DB config from .env; nothing was written there. Credentials (also saved root-only at $GENERATED_DIR/$name.dbpass): db=$db_name user=$db_user host=$DB_HOST pass=$db_pass"
            ;;
        charcoal)
            local charcoal_json="$dir/config/config.local.json"
            mkdir -p "$dir/config"
            # Same reasoning as the craft case above — pre-create at 600
            # before json_write's writes. Mirrors json_write's own `{}`
            # init (lib/db.sh) rather than a bare touch: json_write skips
            # that init once the file already exists, so an empty (not
            # valid-JSON) file here would break its first yq eval -i.
            [[ -f "$charcoal_json" ]] || printf '{}\n' > "$charcoal_json"
            chmod 600 "$charcoal_json"
            local key; key="$(charcoal_db_key "$charcoal_json")"
            json_write "$charcoal_json" '.default_database' "$key"
            json_write "$charcoal_json" ".databases.${key}.hostname" "$DB_HOST"
            json_write "$charcoal_json" ".databases.${key}.database" "$db_name"
            json_write "$charcoal_json" ".databases.${key}.username" "$db_user"
            json_write "$charcoal_json" ".databases.${key}.password" "$db_pass"
            chown "$owner:www-data" "$charcoal_json"
            # 600, not 640 — see the craft case above.
            chmod 600 "$charcoal_json"
            ;;
        *)
            write_env_var "$dir/.env" DB_HOST "$DB_HOST"
            write_env_var "$dir/.env" DB_DATABASE "$db_name"
            write_env_var "$dir/.env" DB_USERNAME "$db_user"
            write_env_var "$dir/.env" DB_PASSWORD "$db_pass"
            chown "$owner:www-data" "$dir/.env"
            # 600, not 640 — see the craft case above.
            chmod 600 "$dir/.env"
            ;;
    esac
}

# $1 name (also used as db name/user unless DB_NAME/DB_USER override),
# $2 site dir.
db_ensure() {
    local name="$1" dir="$2"
    local db_name="${DB_NAME:-$name}" db_user="${DB_USER:-$name}"
    local scheme="${DB_ENV_SCHEME:-laravel}"
    # Belt-and-suspenders: parse_config already validates DB_NAME/DB_USER
    # (lib/config.sh) before this runs on every real call path, but this
    # is the actual SQL-execution boundary — don't rely solely on every
    # future caller remembering to validate upstream.
    validate_db_identifier "$db_name" "database name for '$name'"
    validate_db_identifier "$db_user" "database user for '$name'"
    validate_db_grant_host "$DB_GRANT_HOST"

    local db_pass; db_pass="$(read_db_password "$name" "$dir" "$scheme")"
    if [[ -z "$db_pass" ]]; then
        db_pass="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)"
    fi
    local db_pass_sql; db_pass_sql="$(sql_quote "$db_pass")"

    db_admin_mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'${DB_GRANT_HOST}' IDENTIFIED BY '${db_pass_sql}';
ALTER USER '${db_user}'@'${DB_GRANT_HOST}' IDENTIFIED BY '${db_pass_sql}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'${DB_GRANT_HOST}';
FLUSH PRIVILEGES;
SQL

    write_db_credentials "$name" "$dir" "$db_name" "$db_user" "$db_pass" "$scheme"
    log_info "database '$db_name' ready (user '$db_user'@'$DB_GRANT_HOST', scheme=$scheme)"
}

db_drop() {
    local db_name="$1" db_user="$2"
    validate_db_identifier "$db_name" "database name"
    validate_db_identifier "$db_user" "database user"
    validate_db_grant_host "$DB_GRANT_HOST"
    db_admin_mysql <<SQL
DROP DATABASE IF EXISTS \`${db_name}\`;
DROP USER IF EXISTS '${db_user}'@'${DB_GRANT_HOST}';
SQL
    log_info "dropped database '$db_name' and user '$db_user'"
}

# Pipes $1 (a .sql or .sql.gz file already on local disk) into database
# $2, OVERWRITING it — the shared "load a dump into a database" mechanics
# behind restore_site_database (lib/db_backup.sh, from a downloaded
# object-storage backup), cmd_restore_database's --from-file path
# (lib/cmd_restore.sh, explicitly documented as "e.g. a client-provided
# export"), and seed_preview_database (lib/preview.sh).
#
# $3/$4 are the SITE'S OWN db_user/db_pass (read_db_password, or
# freshly minted by db_ensure) — deliberately NEVER the admin connection.
# A dump is content, not something this tool wrote and controls (most
# clearly true for --from-file, but the same file-format applies to
# every source here) — connecting as admin/root to "just set the default
# schema" would let arbitrary SQL in it DROP a different database,
# CREATE USER, GRANT itself more privileges, or read mysql.* directly,
# none of which the schema-selection argument has any bearing on. The
# site's own DB user is scoped to exactly this one database and was
# never granted WITH GRANT OPTION (see db_ensure), so none of that is
# reachable no matter what the dump contains. Same local-vs-remote
# connection logic as db_admin_mysql, so it works whether the database
# is co-located or on a dedicated init-db server; MYSQL_PWD, same
# pattern cmd_doctor.sh already uses for a site's own credentials.
#
# Strips mysqldump's own DEFINER=`user`@`host` (emitted for every view/
# routine/trigger/event when --routines/--triggers/--events are set —
# see dump_database) down to DEFINER=CURRENT_USER first. Two reasons:
# a scoped, non-SUPER user typically can't even CREATE an object naming
# someone ELSE as DEFINER in the first place — left unstripped, importing
# our OWN backups (dumped by the admin account) would just fail outright
# under the new scoped connection; and for a hostile dump specifically,
# this closes the "routine/view keeps running with an elevated definer's
# privileges forever after" angle, on top of (not instead of) the scoped
# connection itself already blocking it at import time.
load_sql_dump_into_db() {
    local file="$1" db_name="$2" db_user="$3" db_pass="$4"
    validate_db_identifier "$db_name" "database name"
    validate_db_identifier "$db_user" "database user"
    local -a reader
    if [[ "$file" == *.gz ]]; then
        reader=(gunzip -c "$file")
    else
        reader=(cat "$file")
    fi
    local ok=1
    if [[ "$DB_HOST" == "127.0.0.1" || "$DB_HOST" == "localhost" ]]; then
        "${reader[@]}" | sed -E 's/DEFINER=`[^`]*`@`[^`]*`/DEFINER=CURRENT_USER/g' \
            | MYSQL_PWD="$db_pass" mysql -u "$db_user" "$db_name" || ok=0
    else
        "${reader[@]}" | sed -E 's/DEFINER=`[^`]*`@`[^`]*`/DEFINER=CURRENT_USER/g' \
            | MYSQL_PWD="$db_pass" mysql -u "$db_user" -h "$DB_HOST" "$db_name" || ok=0
    fi
    [[ "$ok" -eq 1 ]]
}
