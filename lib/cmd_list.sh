#!/usr/bin/env bash
# `list` — table of provisioned sites: name, PHP version, docroot, DB
# name, last deploy (git short SHA + date), and preview info if any.

# Resolves php/docroot/db for $1, preview-aware (so a shared-mode
# preview's DB column shows its parent's actual database, not its own
# unused name), printed as one tab-separated line. Called via command
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
    printf '%s\t%s\t%s\n' "$PHP_VERSION" "$DOCROOT" "$DB_NAME"
}

cmd_list() {
    load_conf

    printf '%-20s %-6s %-20s %-16s %-10s %-12s %s\n' \
        "NAME" "PHP" "DOCROOT" "DB" "SHA" "LAST DEPLOY" "PREVIEW"

    local site_path name
    for site_path in "$SITES_ROOT"/*/; do
        [[ -d "$site_path" ]] || continue
        name="$(basename "$site_path")"
        is_provisioned "$name" || continue

        local php="?" docroot="" db="$name" row
        row="$(list_row_config "$name" 2>/dev/null)"
        if [[ -n "$row" ]]; then
            IFS=$'\t' read -r php docroot db <<< "$row"
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

        printf '%-20s %-6s %-20s %-16s %-10s %-12s %s\n' \
            "$name" "$php" "${docroot:-.}" "$db" "$sha" "$when" "$preview"
    done
}
