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
# to the parent project's currently-resolved config when the branch has
# none of its own (rather than requiring a persisted sidecar per
# preview), and in shared mode forces DB_NAME/DB_USER/DB_ENV_SCHEME to
# the parent's, freshly re-read every call — never cached, so it always
# tracks whatever the parent's database actually is right now. Used
# identically by provision-preview, deploy-preview, and remove-preview,
# so none of them can drift from what the others would resolve.
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
        log_warn "'$name' has no .ddev/config.yaml — reusing '$project's resolved php/docroot/deploy-steps as a starting point"
        cp "$GENERATED_DIR/$project.steps" "$GENERATED_DIR/$name.steps" 2>/dev/null || : > "$GENERATED_DIR/$name.steps"
        # Hostnames/fqdns are per-vhost and NOT reused: the parent's
        # vhost already claims them, reusing them here would clash.
        ADDITIONAL_HOSTNAMES=()
        ADDITIONAL_FQDNS=()
        # DB_NAME/DB_USER/DB_ENV_SCHEME are currently leftover from
        # parsing $project just above — reset to this preview's own
        # default identity (what parse_config would give it if there
        # were a config to read) rather than silently inheriting the
        # parent's, which parse_config never actually resolved for it.
        DB_NAME="$name"
        DB_USER="$name"
        DB_ENV_SCHEME="$project_scheme"
    else
        die "no .ddev/config.yaml on branch for '$name' and '$project' isn't provisioned to fall back to — add .ddev/config.yaml to the repo, or provision '$project' first"
    fi

    PREVIEW_PROJECT_DB_NAME="$project_db_name"
    if [[ "$mode" == "shared" ]]; then
        [[ -n "$project_db_name" ]] || die "couldn't resolve '$project's database — is it provisioned with a readable config?"
        DB_NAME="$project_db_name"
        DB_USER="$project_db_user"
        DB_ENV_SCHEME="$project_scheme"
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
