#!/usr/bin/env bash
# The read index: each site's `api sites` summary, `list` row and
# resolved config, kept on disk so a read that finds nothing changed is a
# `cat`, not a parse_config per site.
#
#   $INDEX_DIR/<site>.summary   one JSON line (api_site_summary)
#   $INDEX_DIR/<site>.row       list_row's \x1f-separated line
#   $INDEX_DIR/<site>.config    two lines: the config object (or null),
#                               then config_error (or empty)
#   $INDEX_DIR/<site>.fp        the fingerprint these were built from
#
# Correctness never depends on anyone remembering to refresh a row: the
# fingerprint covers every file a row is computed from, and a mismatch
# rebuilds it. It's INDEX_VERSION, provisioner.conf, then one line per
# input file that exists — path, inode, mtime (ns), size, and a
# symlink's target — all sites' inputs from a single `stat` run.
#
# Code inside the checkout only changes with a deploy, which moves
# `current` (or, for an in-place preview, HEAD's ref): those are inputs,
# so .nvmrc, package.json etc. inside a release are covered by them; the
# common ones are listed too, for in-place edits.
#
# Reads never take the site lock: a page mustn't wait on a deploy. Rows
# are written to temp files and renamed, .fp last, so a reader sees the
# old row or the new one, and a crash mid-build leaves a stale .fp that
# the next read rebuilds.

INDEX_DIR="$DDEPLOY_STATE/index"
# Bump when a row's content or the fingerprint's inputs change: every
# row rebuilds on the next read.
INDEX_VERSION=1

# Prints the input files of site $1, one per line (missing ones too:
# stat skips them, and a file appearing changes the fingerprint).
index_inputs() {
    local name="$1" root="$SITES_ROOT/$1" co g="$GENERATED_DIR"
    if [[ -L "$root/current" ]]; then co="$root/current"; else co="$root"; fi
    printf '%s\n' "$root/current" "$root" \
        "$co/.ddev/config.yaml" "$co/.ddeploy/config.yaml" \
        "$g/$name.yaml" "$g/$name.override.yaml" "$g/$name.preview" \
        "$g/$name.deploy-branch" "$g/$name.deploys" "$g/$name.deployed-sha" \
        "$co/package.json" "$co/package-lock.json" "$co/pnpm-lock.yaml" "$co/yarn.lock" \
        "$co/.nvmrc" "$co/.node-version" "$co/composer.json" \
        "$co/.git/HEAD" "$co/.git/config" "$co/.git/packed-refs" \
        "$EVENTS_DIR/$name.jsonl" "/etc/nginx/sites-available/$name.conf"
    local head=""
    [[ -f "$co/.git/HEAD" ]] && read -r head < "$co/.git/HEAD"
    [[ "$head" == "ref: "* ]] && printf '%s\n' "$co/.git/${head#ref: }"
    # A preview's config is resolved through its parent's.
    local line project=""
    if [[ -f "$g/$name.preview" ]]; then
        while IFS= read -r line; do
            [[ "$line" == PROJECT=* ]] && project="${line#PROJECT=}"
        done < "$g/$name.preview"
    fi
    if [[ -n "$project" && "$project" =~ $NAME_RE ]]; then
        printf '%s\n' "$g/$project.yaml" "$g/$project.override.yaml"
    fi
    return 0
}

# Sets INDEX_FP[<site>] for every site in "$@": the fleet part, then the
# stat lines of that site's inputs. One stat process for all of them.
declare -gA INDEX_FP=()
index_fingerprints() {
    INDEX_FP=()
    local fleet="v$INDEX_VERSION"$'\n'
    fleet+="$(stat -c '%n|%i|%.9Y|%s' "$CONF_FILE" 2>/dev/null || true)"$'\n'
    local -A owner=()
    local -a paths=()
    local name p
    for name in "$@"; do
        INDEX_FP["$name"]="$fleet"
        while IFS= read -r p; do
            [[ -n "${owner[$p]+x}" ]] && owner["$p"]+=" $name" || owner["$p"]="$name"
            paths+=("$p")
        done < <(index_inputs "$name")
    done
    [[ "${#paths[@]}" -gt 0 ]] || return 0
    local line path n
    while IFS= read -r line; do
        path="${line%%|*}"
        for n in ${owner[$path]-}; do INDEX_FP["$n"]+="$line"$'\n'; done
    done < <(stat -c '%n|%i|%.9Y|%s|%N' "${paths[@]}" 2>/dev/null || true)
}

# True when site $1's stored row was built from INDEX_FP[$1].
index_fresh() {
    local name="$1" old=""
    [[ -f "$INDEX_DIR/$name.fp" && -f "$INDEX_DIR/$name.summary" && -f "$INDEX_DIR/$name.row" && -f "$INDEX_DIR/$name.config" ]] || return 1
    IFS= read -r -d '' old < "$INDEX_DIR/$name.fp" || true
    [[ "$old" == "${INDEX_FP[$name]}" ]]
}

# Rebuilds site $1's row from scratch and stores it with fingerprint
# INDEX_FP[$1] (computed by the caller BEFORE the build: if an input
# changes mid-build, the stored fingerprint is already stale, and the
# next read rebuilds again).
index_build() {
    local name="$1" fp="${INDEX_FP[$1]-}"
    mkdir -p "$INDEX_DIR"
    chmod 700 "$INDEX_DIR"
    local row config config_error="" errf
    row="$(list_row "$name" 2>/dev/null)" || true
    errf="$(mktemp)"
    if ! config="$(api_site_config "$name" 2>"$errf")"; then
        config=null
        config_error="$(grep -E '^\[error\]' "$errf" | tail -n 1 | sed 's/^\[error\] *//' || true)"
        [[ -n "$config_error" ]] || config_error="$(tail -n 1 "$errf")"
    fi
    rm -f "$errf"
    local t="$INDEX_DIR/.$name.$BASHPID"
    printf '%s\n' "$row" > "$t.row"
    api_site_summary "$name" "$row" > "$t.summary"
    printf '%s\n%s\n' "${config//$'\n'/}" "${config_error//$'\n'/ }" > "$t.config"
    printf '%s' "$fp" > "$t.fp"
    mv -f "$t.row" "$INDEX_DIR/$name.row"
    mv -f "$t.summary" "$INDEX_DIR/$name.summary"
    mv -f "$t.config" "$INDEX_DIR/$name.config"
    mv -f "$t.fp" "$INDEX_DIR/$name.fp"
}

# Makes every row of "$@" current: fingerprints them all, rebuilds the
# stale ones in parallel. Afterwards $INDEX_DIR/<site>.* can be read.
index_refresh() {
    [[ $# -gt 0 ]] || return 0
    # Rows are built from the config (where sites live, the base domain):
    # without it loaded — a caller outside load_conf, like run_notifying's
    # closing event — there's nothing to build from. Not an error: the
    # next `api sites` or `list` rebuilds whatever went stale.
    [[ -n "${SITES_ROOT:-}" && -n "${BASE_DOMAIN:-}" ]] || return 0
    index_fingerprints "$@"
    local -a stale=()
    local name
    for name in "$@"; do
        index_fresh "$name" || stale+=("$name")
    done
    INDEX_REBUILT="${#stale[@]}"
    [[ "${#stale[@]}" -gt 0 ]] || return 0
    parallel_map index_build "${stale[@]}" >/dev/null
}

# Removes site $1's row (the site is gone).
index_forget() {
    rm -f "$INDEX_DIR/$1".{summary,row,config,fp}
}
