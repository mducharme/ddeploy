#!/usr/bin/env bash
# Branch preview environments: <project>-<branch> gets its own vhost,
# docroot, and Linux/FPM identity, but — unlike a normal site — its
# database and uploads are usually the parent project's own, not fresh
# ones. See README "Branch previews" for why: on a pre-launch project the
# database *is* the client's content, and a preview needs continuity with
# it (a feature branch's migration needs to run against, and the client
# needs to enter content into, the same data the main site has), not an
# isolated copy that content silently vanishes into when the preview is
# torn down. PREVIEW_DB_MODE picks the default; --isolated/--shared
# override it per preview:
#
#   shared   - reuses the parent's DB and Linux user; uploads are
#              symlinked to the parent's actual files. No new DB is
#              created; migrations run against the parent's real data.
#   isolated - a completely normal, fully separate site (own DB, own
#              user, own uploads) — optionally seeded once at creation
#              from the parent's current DB/uploads (PREVIEW_SEED).

# Deterministic name for a (project, branch) pair — same inputs always
# produce the same <name>, so callers never need to remember one.
# Lowercases, collapses anything outside [a-z0-9-] to '-', and truncates
# to fit NAME_RE's 28-char cap (dropping the tail and appending a 6-digit
# checksum of the untruncated string, so two branches that would
# otherwise truncate to the same prefix still land on different names).
preview_slug() {
    local project="$1" branch="$2"
    local raw="${project}-${branch}"
    local slug
    slug="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's#[/_[:space:]]+#-#g; s#[^a-z0-9-]##g; s#-+#-#g; s#^-+##; s#-+$##')"
    [[ -n "$slug" ]] || die "project '$project' + branch '$branch' produced an empty name"
    if [[ "${#slug}" -gt 28 ]]; then
        local sum; sum="$(printf '%s' "$raw" | cksum | cut -d' ' -f1 | tail -c 7)"
        slug="${slug:0:21}-${sum}"
    fi
    [[ "$slug" =~ ^[a-z0-9] ]] || slug="p${slug:1}"
    echo "$slug"
}

# Public URL for a (project, branch) preview. Deterministic — the site
# does not have to exist yet. Used by `preview-url` and the PR comment.
preview_url() {
    printf 'https://%s.%s\n' "$(preview_slug "$1" "$2")" "$BASE_DOMAIN"
}

# --- .preview metadata: marks a site as a preview and records what it's
# a preview of, so deploy/remove/list/prune know how to treat it. ---

preview_meta_file() { echo "$GENERATED_DIR/$1.preview"; }

write_preview_meta() {
    local name="$1" project="$2" branch="$3" mode="$4"
    mkdir -p "$GENERATED_DIR"
    cat > "$(preview_meta_file "$name")" <<EOF
PROJECT=$project
BRANCH=$branch
MODE=$mode
EOF
}

# Sets PREVIEW_PROJECT/PREVIEW_BRANCH/PREVIEW_MODE; returns 1 (nothing
# set) if $1 isn't a preview.
read_preview_meta() {
    local name="$1" f; f="$(preview_meta_file "$name")"
    [[ -f "$f" ]] || return 1
    PREVIEW_PROJECT="$(awk -F= '/^PROJECT=/{print $2}' "$f")"
    PREVIEW_BRANCH="$(awk -F= '/^BRANCH=/{print $2}' "$f")"
    PREVIEW_MODE="$(awk -F= '/^MODE=/{print $2}' "$f")"
}

is_preview() { [[ -f "$(preview_meta_file "$1")" ]]; }

# Resolves a preview's config exactly like parse_config, but: falls back
# to the parent project's config file when the branch has none of its own
# (rather than requiring a persisted sidecar per preview), and in shared
# mode forces DB_NAME/DB_USER/DB_ENV_SCHEME to the parent's, freshly
# re-read every call — never cached, so it always tracks whatever the
# parent's database actually is right now. Used identically by
# provision-preview, deploy-preview, and remove-preview, so none of them
# can drift from what the others would resolve.
#
# Either way the preview's own generated/<name>.override.yaml (seeded
# from the parent's by seed_preview_override) is what parse_config
# applies on top, since it's parsed under the preview's own name.
#
# $1 name, $2 project, $3 mode. Sets the same globals parse_config does.
resolve_preview_config() {
    local name="$1" project="$2" mode="$3"
    local project_db_name="" project_db_user="" project_scheme=""

    local project_cfg; project_cfg="$(resolve_config_path "$project")"
    if [[ -n "$project_cfg" ]]; then
        parse_config "$project" "$project_cfg" 0
        project_db_name="$DB_NAME"; project_db_user="$DB_USER"; project_scheme="$DB_ENV_SCHEME"
    fi

    local cfg_path; cfg_path="$(resolve_config_path "$name")"
    if [[ -n "$cfg_path" ]]; then
        # skip_name_check=1: when this is the branch's own real
        # .ddev/config.yaml, its name: field is the project's, not this
        # preview's derived slug — that's expected, not a sign of the
        # wrong repo (see parse_config).
        parse_config "$name" "$cfg_path" 1 1
    elif [[ -n "$project_cfg" ]]; then
        log_warn "'$name' has no .ddev/config.yaml — reusing '$project's config ($project_cfg) as a starting point"
        # Parsed under the preview's own name, not the project's: its
        # deploy steps land in $name.steps (never rewriting the parent's
        # own), and the preview's override file, not the parent's, is
        # the one applied on top.
        parse_config "$name" "$project_cfg" 1 1
        # DB_NAME/DB_USER from the parent's file are the parent's —
        # reset to this preview's own default identity (what
        # parse_config would give it if there were a config to read)
        # rather than silently inheriting them.
        DB_NAME="$name"
        DB_USER="$name"
        DB_ENV_SCHEME="$project_scheme"
    else
        die "no .ddev/config.yaml on branch for '$name' and '$project' isn't provisioned to fall back to — add .ddev/config.yaml to the repo, or provision '$project' first"
    fi

    # Hostnames/fqdns are per-vhost: whatever the repo (or the parent's
    # config) declares belongs to the parent's vhost, which already
    # claims them — a preview inheriting them would clash with it. Only
    # an explicit entry in the preview's own override file counts;
    # custom domains are never set up for previews at all.
    local own_override; own_override="$(override_config_path "$name")"
    mapfile -t ADDITIONAL_HOSTNAMES < <(read_ext_array "$own_override" "" "" '.additional_hostnames[]')
    ADDITIONAL_FQDNS=()

    PREVIEW_PROJECT_DB_NAME="$project_db_name"
    if [[ "$mode" == "shared" ]]; then
        [[ -n "$project_db_name" ]] || die "couldn't resolve '$project's database — is it provisioned with a readable config?"
        DB_NAME="$project_db_name"
        DB_USER="$project_db_user"
        DB_ENV_SCHEME="$project_scheme"
    fi
}

# Gives a new preview its own generated/<name>.override.yaml, starting as
# a copy of the parent's operator overrides — so a preview behaves like
# its parent by default (same basic_auth, php_ini-free knobs, build
# settings...) but can then be tuned on its own with
# `ddeploy override <preview> ...` without touching the parent.
# Never overwrites an existing file (a re-run of provision-preview keeps
# whatever the operator changed). The parent's hostnames/fqdns are
# dropped — they belong to the parent's vhost.
seed_preview_override() {
    local name="$1" project="$2"
    local own; own="$(override_config_path "$name")"
    [[ -e "$own" ]] && return 0
    local parent; parent="$(override_config_path "$project")"
    mkdir -p "$GENERATED_DIR"
    if [[ -s "$parent" ]]; then
        yq eval 'del(.additional_hostnames) | del(.additional_fqdns)' "$parent" > "$own"
    else
        echo "{}" > "$own"
    fi
    log_info "'$name': created its own override file from '$project's (edit with 'ddeploy override $name ...')"
}

# --- the preview's own credential file (.env / config.local.json) -----

# The URL rewrites/key names below, per scheme, for the one-time seed.
preview_url_key_for_scheme() {
    case "$1" in
        craft) echo PRIMARY_SITE_URL ;;
        laravel) echo APP_URL ;;
    esac
}

db_password_key_for_scheme() {
    case "$1" in
        craft) echo CRAFT_DB_PASSWORD ;;
        laravel) echo DB_PASSWORD ;;
    esac
}

# Links the preview's credential file into the persistent store (so
# `git reset --hard` on deploy-preview, or anything else touching the
# checkout, can't lose it, and `ddeploy env <preview>` edits it like
# any other site's) and — the first time only — seeds it with a copy of
# the parent's, so the preview gets every non-DB setting the parent has
# (CRAFT_SECURITY_KEY, mail config, API keys, ...) instead of a bare
# file with just DB credentials. Sets PREVIEW_CRED_SEEDED=1 when it
# copied; the caller then rewrites DB credentials (write_db_credentials
# / db_ensure) and URLs (rewrite_preview_urls) on top of the copy.
#
# $1 name $2 dir $3 project $4 project_dir $5 scheme $6 owner $7 mode
link_preview_credential_file() {
    local name="$1" dir="$2" project="$3" project_dir="$4" scheme="$5" owner="$6" mode="$7"
    PREVIEW_CRED_SEEDED=0
    local cred; cred="$(persistent_db_credential_path "$scheme")"
    [[ -n "$cred" ]] || return 0
    local target="$PERSISTENT_ROOT/$name/$cred"
    local fresh=0
    [[ -e "$target" || ( -e "$dir/$cred" && ! -L "$dir/$cred" ) ]] || fresh=1

    ensure_persistent_link "$name" "$dir" "$cred" "file" "$owner"
    [[ "$fresh" -eq 1 ]] || return 0

    local parent_file="$project_dir/$cred"
    if [[ ! -f "$parent_file" ]]; then
        log_info "'$project' has no $cred to seed '$name' from — starting from an empty one"
        return 0
    fi
    install -m 600 -o "$owner" -g www-data /dev/null "$target"
    cat "$parent_file" > "$target"
    PREVIEW_CRED_SEEDED=1

    # Isolated mode gets its own DB user; drop the parent's password so
    # db_ensure mints a fresh one instead of reusing it for that user.
    if [[ "$mode" != "shared" ]]; then
        if [[ "$scheme" == "charcoal" ]]; then
            local key; key="$(charcoal_db_key "$target")"
            yq eval -i -o=json "del(.databases.${key}.password)" "$target"
        else
            local pkey; pkey="$(db_password_key_for_scheme "$scheme")"
            [[ -n "$pkey" ]] && unset_env_var "$target" "$pkey"
        fi
    fi
    log_info "'$name': seeded its $cred from '$project's (DB credentials and URL rewritten for the preview)"
}

# One-time, right after the seed above: points URLs at the preview
# instead of the parent. Replaces every literal occurrence of the
# parent's https://<project>.$BASE_DOMAIN, then sets the scheme's
# canonical URL key outright — the parent's may well be a custom domain
# (https://www.client.com) that a preview must never claim.
rewrite_preview_urls() {
    local name="$1" dir="$2" project="$3" scheme="$4"
    local cred; cred="$(persistent_db_credential_path "$scheme")"
    [[ -n "$cred" ]] || return 0
    local file="$PERSISTENT_ROOT/$name/$cred"
    [[ -f "$file" ]] || return 0
    local from="https://$project.$BASE_DOMAIN" to="https://$name.$BASE_DOMAIN"
    local tmp; tmp="$(mktemp)"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "${line//"$from"/"$to"}"
    done < "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
    local key; key="$(preview_url_key_for_scheme "$scheme")"
    if [[ -n "$key" ]]; then
        if [[ "$scheme" == "craft" ]] || [[ -n "$(read_env_var "$file" "$key" || true)" ]]; then
            write_env_var "$file" "$key" "$to"
        fi
    fi
}

# --- shared mode: link to the parent's existing DB and uploads ---

# Copies the parent's DB credentials (name/user/password) into the
# preview's own env/config, in whatever format DB_ENV_SCHEME calls for —
# no new database, no new grants, this is the same DB the parent uses.
link_shared_database() {
    local name="$1" dir="$2" project="$3" project_dir="$4" scheme="$5"
    local db_pass; db_pass="$(read_db_password "$project" "$project_dir" "$scheme")"
    [[ -n "$db_pass" ]] || die "couldn't read '$project's existing DB password (scheme=$scheme) from $project_dir — is it actually provisioned?"
    # Owner is the parent's user (www-$project), matching install_fpm_pool
    # for a shared preview — that's who actually needs to read this file.
    write_db_credentials "$name" "$dir" "$DB_NAME" "$DB_USER" "$db_pass" "$scheme" "www-$project"
    log_info "linked '$name' to '$project's database (shared, not copied)"
}

# Replaces each of the preview's own upload dirs (as cloned — empty, or
# absent if gitignored) with a symlink to the parent's actual files at
# the same relative path.
link_shared_uploads() {
    local dir="$1" project_dir="$2"; shift 2
    local d target link
    for d in "$@"; do
        target="$project_dir/$d"
        link="$dir/$d"
        if [[ ! -d "$target" ]]; then
            log_warn "shared uploads: parent has no $d, skipping"
            continue
        fi
        rm -rf "$link"
        mkdir -p "$(dirname "$link")"
        ln -s "$target" "$link"
        log_info "linked upload dir '$d' -> parent's copy"
    done
}

# --- isolated mode: one-time seed from the parent's current state ---

# Dumps the parent's DB (as admin — that dump is this tool's own trusted
# output) and restores it into the preview's own (already-created)
# database as THAT database's own user/pass ($3/$4 — never admin, see
# load_sql_dump_into_db in lib/db.sh for why), via the same shared import
# path restore/backup use — not a separate admin pipe of its own.
seed_preview_database() {
    local project_db="$1" preview_db="$2" preview_user="$3" preview_pass="$4"
    local tmp; tmp="$(mktemp -d)"
    local dump="$tmp/seed.sql.gz"
    log_info "seeding '$preview_db' from '$project_db'"
    if ! dump_database "$project_db" "$dump"; then
        log_warn "seed: dumping '$project_db' failed — leaving the preview's database empty"
        rm -rf "$tmp"
        return 1
    fi
    local ok=1
    load_sql_dump_into_db "$dump" "$preview_db" "$preview_user" "$preview_pass" || ok=0
    rm -rf "$tmp"
    [[ "$ok" -eq 1 ]]
}

# Copies (not links — isolated means isolated) the parent's current
# upload dir contents into the preview's own.
seed_preview_uploads() {
    local dir="$1" project_dir="$2"; shift 2
    local d
    for d in "$@"; do
        if [[ ! -d "$project_dir/$d" ]]; then
            log_warn "seed uploads: parent has no $d, skipping"
            continue
        fi
        mkdir -p "$dir/$d"
        rsync -a "$project_dir/$d/" "$dir/$d/"
        log_info "seeded upload dir '$d' from parent's current copy"
    done
}
