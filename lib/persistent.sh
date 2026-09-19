#!/usr/bin/env bash
# Persistent files: upload_dirs, a site's DB credential file, and any
# declared persistent_files: live in $PERSISTENT_ROOT/<name>/, outside the
# ephemeral git checkout — `remove --purge-files` only ever deletes the
# checkout, so this content survives it. `provision` re-linking after a
# purge is the restore: no separate command needed. See README
# "Persistent files".

# Replaces $dir/$path (a file or directory, however it currently exists —
# real, empty, or already-linked) with a symlink into
# $PERSISTENT_ROOT/$name/$path, migrating whatever's really there the
# first time so an already-provisioned site adopts this without losing
# anything. Idempotent: a re-run against an already-correct symlink is a
# no-op. $4 kind is "file" or "dir" — needed because a file-kind path
# (e.g. .env) commonly doesn't exist yet on a brand-new checkout (it's
# gitignored), so there's nothing to infer the kind from at that point.
# $5 (optional) owner — defaults to the site's own www-<name>, same
# convention as apply_permissions/write_db_credentials.
ensure_persistent_link() {
    local name="$1" dir="$2" path="$3" kind="$4"
    local owner="${5:-www-$name}"
    local link="$dir/$path" target="$PERSISTENT_ROOT/$name/$path"

    [[ -L "$link" && "$(readlink "$link")" == "$target" ]] && return 0

    mkdir -p "$(dirname "$target")"
    if [[ ! -e "$target" ]]; then
        if [[ -e "$link" && ! -L "$link" ]]; then
            mv "$link" "$target"
        elif [[ "$kind" == "dir" ]]; then
            mkdir -p "$target"
        fi
        # kind == "file" and nothing exists yet: leave $target absent —
        # its first writer (write_db_credentials's write_env_var, which
        # touches the file first) creates it through the dangling symlink.
    fi
    if [[ -e "$target" ]]; then
        chown -R "$owner:www-data" "$target"
    fi

    rm -rf "$link"
    mkdir -p "$(dirname "$link")"
    ln -s "$target" "$link"
    log_info "linked '$path' -> persistent store ($target)"
}

# Prints the site-root-relative DB credential path for $1 (DB_ENV_SCHEME),
# or nothing for a scheme that doesn't write inside the checkout at all
# (none — already outside SITES_ROOT, in $GENERATED_DIR).
persistent_db_credential_path() {
    case "$1" in
        charcoal) echo "config/config.local.json" ;;
        none) ;;
        *) echo ".env" ;;
    esac
}

# Links every persistent path for a normal (non-preview) site: declared
# upload_dirs (dir), declared persistent_files (file or dir, trailing '/'
# marks a dir), and the DB credential file for the resolved
# DB_ENV_SCHEME. Expects UPLOAD_DIRS[]/PERSISTENT_FILES[]/DB_ENV_SCHEME to
# already be set (parse_config). $3 (optional) owner, as
# ensure_persistent_link.
link_persistent_files() {
    local name="$1" dir="$2"
    local owner="${3:-www-$name}"

    local d
    for d in "${UPLOAD_DIRS[@]}"; do
        ensure_persistent_link "$name" "$dir" "$d" "dir" "$owner"
    done

    local entry path kind
    for entry in "${PERSISTENT_FILES[@]}"; do
        if [[ "$entry" == */ ]]; then
            kind="dir"; path="${entry%/}"
        else
            kind="file"; path="$entry"
        fi
        ensure_persistent_link "$name" "$dir" "$path" "$kind" "$owner"
    done

    local cred_path; cred_path="$(persistent_db_credential_path "$DB_ENV_SCHEME")"
    if [[ -n "$cred_path" ]]; then
        ensure_persistent_link "$name" "$dir" "$cred_path" "file" "$owner"
    fi
}
