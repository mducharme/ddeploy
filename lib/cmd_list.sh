#!/usr/bin/env bash
# `list` — table of provisioned sites: name, PHP version, Node version
# (+ whether it builds a frontend), docroot, DB name, last deploy (git
# short SHA + date), and preview info if any.

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

cmd_list() {
    load_conf

    printf '%-20s %-6s %-11s %-20s %-16s %-10s %-12s %s\n' \
        "NAME" "PHP" "NODE" "DOCROOT" "DB" "SHA" "LAST DEPLOY" "PREVIEW"

    local site_path name
    for site_path in "$SITES_ROOT"/*/; do
        [[ -d "$site_path" ]] || continue
        name="$(basename "$site_path")"
        is_provisioned "$name" || continue

        local php="?" node="?" docroot="" db="$name" row
        row="$(list_row_config "$name" 2>/dev/null)"
        if [[ -n "$row" ]]; then
            IFS=$'\x1f' read -r php docroot db node <<< "$row"
            php="${php:-?}"
            db="${db:-$name}"
        fi

        local preview="-"
        if is_preview "$name" && read_preview_meta "$name" 2>/dev/null; then
            preview="$PREVIEW_PROJECT/$PREVIEW_BRANCH ($PREVIEW_MODE)"
        fi

        local sha="-" when="-" checkout
        checkout="$(site_dir "$name")"
        if [[ -d "$checkout/.git" ]]; then
            sha="$(git -C "$checkout" log -1 --format=%h 2>/dev/null || echo -)"
            when="$(git -C "$checkout" log -1 --format=%cd --date=short 2>/dev/null || echo -)"
        fi

        printf '%-20s %-6s %-11s %-20s %-16s %-10s %-12s %s\n' \
            "$name" "$php" "${node:--}" "${docroot:-.}" "$db" "$sha" "$when" "$preview"
    done
}
