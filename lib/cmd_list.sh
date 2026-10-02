#!/usr/bin/env bash
# `list` — table of provisioned sites: name, PHP version, Node version
# (+ whether it builds a frontend), docroot, DB name, checked-out branch,
# last deploy (git short SHA + date), and whether it's a preview (+ mode).

# Resolves php/docroot/db for $1, preview-aware (so a shared-mode
# preview's DB column shows its parent's actual database, not its own
# unused name), printed as one \x1f-separated line. Called via command
# substitution deliberately: both parse_config and resolve_preview_config
# can die() on a malformed config, and running it in a subshell means
# that only blanks out this one row instead of the whole `list` run.
list_row_config() {
    local name="$1"
    if is_preview "$name"; then
        read_preview_meta "$name" || return 1
        resolve_preview_config "$name" "$PREVIEW_PROJECT" "$PREVIEW_MODE"
    else
        local cfg_path; cfg_path="$(resolve_config_path "$name")"
        [[ -n "$cfg_path" ]] || return 1
        parse_config "$name" "$cfg_path" 0
    fi
    # Node column: the resolved spec, "+build" when a frontend build
    # runs; "-" for a site that only rides on DEFAULT_NODE and builds
    # nothing (it has Node on PATH, but doesn't use it for anything).
    local node="-"
    if [[ "$NODE_ENABLED" == "true" && -n "${NODE_VERSION_SPEC:-}" ]]; then
        if [[ "$BUILD_ENABLED" == "true" ]]; then
            node="$NODE_VERSION_SPEC+build"
        elif [[ "$NODE_VERSION_SOURCE" != "default" ]]; then
            node="$NODE_VERSION_SPEC"
        fi
    fi
    # \x1f, not a tab: tab is IFS whitespace to `read`, so an empty
    # DOCROOT (two tabs in a row) would collapse and shift DB/NODE left.
    printf '%s\x1f%s\x1f%s\x1f%s\n' "$PHP_VERSION" "$DOCROOT" "$DB_NAME" "$node"
}

# One full \x1f-separated table row for site $1, on stdout.
list_row() {
    local name="$1"
    local php="?" node="?" docroot="" db="$name" row
    # || true: under set -e a failed assignment would end the row (and
    # outside the parallel wrapper, the whole list) instead of showing "?".
    row="$(list_row_config "$name" 2>/dev/null)" || true
    if [[ -n "$row" ]]; then
        IFS=$'\x1f' read -r php docroot db node <<< "$row"
        php="${php:-?}"
        db="${db:-$name}"
    fi

    # Project/branch are already in the name and BRANCH column, so
    # PREVIEW is just a marker plus the DB mode.
    local preview="-" branch="-"
    if is_preview "$name" && read_preview_meta "$name" 2>/dev/null; then
        preview="✓ $PREVIEW_MODE"
        branch="$PREVIEW_BRANCH"
    fi

    local sha="-" when="-" checkout
    checkout="$(site_dir "$name")"
    if [[ -d "$checkout/.git" ]]; then
        # Non-previews: whatever the live release has checked out
        # ("-" on a detached HEAD).
        [[ "$branch" != "-" ]] \
            || branch="$(git -C "$checkout" symbolic-ref --short -q HEAD 2>/dev/null || echo -)"
        local last
        last="$(git -C "$checkout" log -1 --format='%h%x1f%cd' --date=short 2>/dev/null || true)"
        [[ -n "$last" ]] && IFS=$'\x1f' read -r sha when <<< "$last"
    fi

    printf '%s\n' "$name"$'\x1f'"$php"$'\x1f'"${node:--}"$'\x1f'"${docroot:-.}"$'\x1f'"$db"$'\x1f'"$branch"$'\x1f'"$sha"$'\x1f'"$when"$'\x1f'"$preview"
}

# Every provisioned site (previews included), one per line, sorted so a
# site's previews follow it. No trailing slash on the glob: "foo/" sorts
# after "foo-bar/" ('-' < '/'), which would list a site's previews
# before it.
provisioned_site_names() {
    local site_path name
    for site_path in "$SITES_ROOT"/*; do
        [[ -d "$site_path" ]] || continue
        name="$(basename "$site_path")"
        is_provisioned "$name" && printf '%s\n' "$name"
    done
    return 0
}

# Runs function $1 once per remaining argument, in parallel, and prints
# each call's stdout in argument order (a failing call just prints
# nothing). Each row is a few dozen yq processes (parse_config) plus git,
# too slow to run one site after another on a fleet of any size. Capped
# at the CPU count (min 8: it's mostly process startup, not CPU-bound
# work).
parallel_map() {
    local fn="$1"; shift
    local -a items=("$@")
    local tmp; tmp="$(mktemp -d)"
    local max; max="$(nproc 2>/dev/null || echo 8)"
    (( max < 8 )) && max=8
    local i
    for i in "${!items[@]}"; do
        { "$fn" "${items[i]}" || true; } > "$tmp/$i" &
        (( $(jobs -rp | wc -l) >= max )) && wait -n
    done
    wait
    for i in "${!items[@]}"; do
        [[ -s "$tmp/$i" ]] && cat "$tmp/$i"
    done
    rm -rf "$tmp"
    return 0
}

cmd_list() {
    load_conf

    local -a names=()
    mapfile -t names < <(provisioned_site_names)

    # Every column is sized to its widest value, so nothing can print
    # until every row is in.
    local -a rows=()
    rows+=("NAME"$'\x1f'"PHP"$'\x1f'"NODE"$'\x1f'"DOCROOT"$'\x1f'"DB"$'\x1f'"BRANCH"$'\x1f'"SHA"$'\x1f'"LAST DEPLOY"$'\x1f'"PREVIEW")
    local row
    while IFS= read -r row; do
        [[ -n "$row" ]] && rows+=("$row")
    done < <(parallel_map list_row "${names[@]}")

    print_table "${rows[@]}"
}

# Prints \x1f-separated rows as space-aligned columns, two spaces apart.
# Padding is done by hand from ${#val} rather than printf's %-Ns, which
# counts bytes: a multibyte value (the ✓, a non-ASCII branch name) would
# otherwise come out short and shift everything after it. ${#val} itself
# only counts characters under a UTF-8 locale, hence C.UTF-8 here (always
# present on Debian/Ubuntu) whatever the caller's — cron and sudo often
# leave plain C/POSIX. The last column isn't padded, so it never leaves
# trailing whitespace.
print_table() {
    local LC_ALL=C.UTF-8
    local -a widths=() cols=()
    local line i n=0
    for line in "$@"; do
        IFS=$'\x1f' read -r -a cols <<< "$line"
        (( ${#cols[@]} > n )) && n=${#cols[@]}
        for i in "${!cols[@]}"; do
            (( ${#cols[i]} > ${widths[i]:-0} )) && widths[i]=${#cols[i]}
        done
    done
    for line in "$@"; do
        IFS=$'\x1f' read -r -a cols <<< "$line"
        for (( i = 0; i < n - 1; i++ )); do
            printf '%s%*s' "${cols[i]:-}" $(( widths[i] - ${#cols[i]} + 2 )) ''
        done
        printf '%s\n' "${cols[n-1]:-}"
    done
}
