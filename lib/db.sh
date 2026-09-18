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

# $1 name (also used as db name/user unless DB_NAME/DB_USER override),
# $2 site dir.
db_ensure() {
    local name="$1" dir="$2"
    local db_name="${DB_NAME:-$name}" db_user="${DB_USER:-$name}"
    local scheme="${DB_ENV_SCHEME:-laravel}"
    local env_file="$dir/.env"
    local cred_file="$GENERATED_DIR/$name.dbpass"
    local charcoal_json="$dir/config/config.local.json"

    # Charcoal's active DB entry is named by default_database (usually
    # "default", but not always — e.g. a project keyed "mysql" alongside
    # a "sqlite" fallback). Read it back if the file already names one;
    # constrain to a safe identifier charset before it's ever interpolated
    # into a yq path expression.
    local charcoal_db_key="default"
    if [[ "$scheme" == "charcoal" ]]; then
        local existing_key
        existing_key="$(json_read "$charcoal_json" '.default_database' || true)"
        [[ "$existing_key" =~ ^[a-zA-Z0-9_]+$ ]] && charcoal_db_key="$existing_key"
    fi

    local db_pass=""
    case "$scheme" in
        craft)    db_pass="$(read_env_var "$env_file" CRAFT_DB_PASSWORD || true)" ;;
        none)     [[ -f "$cred_file" ]] && db_pass="$(cat "$cred_file")" ;;
        charcoal) db_pass="$(json_read "$charcoal_json" ".databases.${charcoal_db_key}.password" || true)" ;;
        *)        db_pass="$(read_env_var "$env_file" DB_PASSWORD || true)" ;;
    esac
    if [[ -z "$db_pass" ]]; then
        db_pass="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)"
    fi

    db_admin_mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'${DB_GRANT_HOST}' IDENTIFIED BY '${db_pass}';
ALTER USER '${db_user}'@'${DB_GRANT_HOST}' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'${DB_GRANT_HOST}';
FLUSH PRIVILEGES;
SQL

    case "$scheme" in
        craft)
            write_env_var "$env_file" CRAFT_DB_DRIVER "mysql"
            write_env_var "$env_file" CRAFT_DB_SERVER "$DB_HOST"
            write_env_var "$env_file" CRAFT_DB_DATABASE "$db_name"
            write_env_var "$env_file" CRAFT_DB_USER "$db_user"
            write_env_var "$env_file" CRAFT_DB_PASSWORD "$db_pass"
            chown "www-$name:www-data" "$env_file"
            chmod 640 "$env_file"
            ;;
        none)
            mkdir -p "$GENERATED_DIR"
            printf '%s' "$db_pass" > "$cred_file"
            chmod 600 "$cred_file"
            log_warn "db_env_scheme=none — this CMS doesn't read DB config from .env; nothing was written there. Credentials (also saved root-only at $cred_file): db=$db_name user=$db_user host=$DB_HOST pass=$db_pass"
            ;;
        charcoal)
            mkdir -p "$dir/config"
            json_write "$charcoal_json" '.default_database' "$charcoal_db_key"
            json_write "$charcoal_json" ".databases.${charcoal_db_key}.hostname" "$DB_HOST"
            json_write "$charcoal_json" ".databases.${charcoal_db_key}.database" "$db_name"
            json_write "$charcoal_json" ".databases.${charcoal_db_key}.username" "$db_user"
            json_write "$charcoal_json" ".databases.${charcoal_db_key}.password" "$db_pass"
            chown "www-$name:www-data" "$charcoal_json"
            chmod 640 "$charcoal_json"
            ;;
        *)
            write_env_var "$env_file" DB_HOST "$DB_HOST"
            write_env_var "$env_file" DB_DATABASE "$db_name"
            write_env_var "$env_file" DB_USERNAME "$db_user"
            write_env_var "$env_file" DB_PASSWORD "$db_pass"
            chown "www-$name:www-data" "$env_file"
            chmod 640 "$env_file"
            ;;
    esac

    log_info "database '$db_name' ready (user '$db_user'@'$DB_GRANT_HOST', scheme=$scheme)"
}

db_drop() {
    local db_name="$1" db_user="$2"
    db_admin_mysql <<SQL
DROP DATABASE IF EXISTS \`${db_name}\`;
DROP USER IF EXISTS '${db_user}'@'${DB_GRANT_HOST}';
SQL
    log_info "dropped database '$db_name' and user '$db_user'"
}
