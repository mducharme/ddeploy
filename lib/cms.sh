#!/usr/bin/env bash
# Best-effort CMS detection, used to pick sensible defaults (docroot,
# deploy steps, DB .env variable naming) instead of guessing one scheme
# for every project. Always overridable — detected values just seed the
# interactive prompts / non-interactive flag gaps and land in the
# sidecar, where they can be hand-edited afterward.
#
# The CLI commands below (craft migrate/all, etc.) are the framework's
# documented defaults, not verified against a real project — treat them
# as a starting point, not a guarantee.

# Prints one of: craftcms, wordpress-bedrock, wordpress, charcoal, "" (unknown)
detect_cms() {
    local dir="$1"
    local composer="$dir/composer.json"
    if [[ -f "$composer" ]]; then
        grep -q '"craftcms/cms"' "$composer" 2>/dev/null && { echo craftcms; return; }
        # Real Charcoal projects vary in which package they depend on
        # directly — the meta-package (charcoal/charcoal), a specific
        # locomotivemtl/charcoal-* component (charcoal-app, -admin,
        # -contrib-*, -presenter, ...), or even a third-party extension
        # under a different vendor entirely (e.g. mcaskill/charcoal-*).
        # Matching "any vendor, package name starting with charcoal"
        # instead of enumerating specific package names holds up against
        # that variety (confirmed against a real project's composer.json
        # that a narrower, enumerated match missed entirely).
        grep -qE '"[a-zA-Z0-9_.-]+/charcoal[a-zA-Z0-9_.-]*"' "$composer" 2>/dev/null && { echo charcoal; return; }
        grep -qE '"roots/(bedrock|wordpress)"' "$composer" 2>/dev/null && { echo wordpress-bedrock; return; }
        grep -q '"johnpbloch/wordpress"' "$composer" 2>/dev/null && { echo wordpress; return; }
    fi
    local sub
    for sub in "" web public htdocs; do
        if [[ -f "$dir/$sub/wp-load.php" || -f "$dir/$sub/wp-config-sample.php" ]]; then
            echo wordpress
            return
        fi
    done
    [[ -f "$dir/craft" ]] && { echo craftcms; return; }
    echo ""
}

# Sets CMS_DOCROOT CMS_COMPOSER_ARGS CMS_MIGRATE_CMD CMS_CACHE_CMD
# CMS_DB_ENV_SCHEME for a detected CMS id (empty id -> generic defaults).
cms_defaults() {
    local cms="$1"
    CMS_DOCROOT=""
    CMS_COMPOSER_ARGS="install"
    CMS_MIGRATE_CMD=""
    CMS_CACHE_CMD=""
    CMS_DB_ENV_SCHEME="laravel"

    case "$cms" in
        craftcms)
            CMS_DOCROOT="web"
            CMS_COMPOSER_ARGS="install --no-dev --optimize-autoloader"
            CMS_MIGRATE_CMD="php craft migrate/all --interactive=0 && php craft project-config/apply --force"
            CMS_CACHE_CMD="php craft clear-caches/all"
            CMS_DB_ENV_SCHEME="craft"
            ;;
        wordpress-bedrock)
            CMS_DOCROOT="web"
            CMS_COMPOSER_ARGS="install --no-dev --optimize-autoloader"
            CMS_DB_ENV_SCHEME="laravel"
            ;;
        wordpress)
            CMS_DOCROOT=""
            CMS_COMPOSER_ARGS="install --no-dev"
            CMS_DB_ENV_SCHEME="none"
            ;;
        charcoal)
            CMS_DOCROOT="www"
            CMS_COMPOSER_ARGS="install --no-dev --optimize-autoloader"
            CMS_DB_ENV_SCHEME="charcoal"
            ;;
    esac
}
