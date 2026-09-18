#!/usr/bin/env bash
# `list` — table of provisioned sites: name, PHP version, docroot, DB
# name, last deploy (git short SHA + date) (§10, §12).

cmd_list() {
    load_conf

    printf '%-20s %-6s %-20s %-16s %-10s %s\n' "NAME" "PHP" "DOCROOT" "DB" "SHA" "LAST DEPLOY"

    local site_path name
    for site_path in "$SITES_ROOT"/*/; do
        [[ -d "$site_path" ]] || continue
        name="$(basename "$site_path")"
        [[ -f "/etc/nginx/sites-available/$name.conf" ]] || continue

        local cfg_path; cfg_path="$(resolve_config_path "$name")"
        local php="?" docroot="" db="$name"
        if [[ -n "$cfg_path" ]]; then
            parse_config "$name" "$cfg_path" 0 2>/dev/null || true
            php="${PHP_VERSION:-?}"
            docroot="${DOCROOT:-}"
            db="${DB_NAME:-$name}"
        fi

        local sha="-" when="-"
        if [[ -d "$site_path/.git" ]]; then
            sha="$(git -C "$site_path" log -1 --format=%h 2>/dev/null || echo -)"
            when="$(git -C "$site_path" log -1 --format=%cd --date=short 2>/dev/null || echo -)"
        fi

        printf '%-20s %-6s %-20s %-16s %-10s %s\n' "$name" "$php" "${docroot:-.}" "$db" "$sha" "$when"
    done
}
