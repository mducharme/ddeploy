#!/usr/bin/env bash
# Best-effort CMS detection, used to pick sensible defaults (docroot,
# deploy steps, DB .env variable naming) instead of guessing one scheme
# for every project. Always overridable — detected values just seed the
# interactive prompts / non-interactive flag gaps and land in the
# sidecar, where they can be hand-edited afterward.
#
# CONFIRM AT BUILD TIME: the CLI commands below (craft migrate/all, etc.)
# are the framework's documented defaults, not verified against a real
# project in this repo. Treat them as a starting point.

# Prints one of: craftcms, wordpress-bedrock, wordpress, charcoal, "" (unknown)
detect_cms() {
    local dir="$1" composer="$dir/composer.json"
    if [[ -f "$composer" ]]; then
        grep -q '"craftcms/cms"' "$composer" 2>/dev/null && { echo craftcms; return; }
        grep -qE '"locomotivemtl/charcoal-(app|core|cms|project-boilerplate)"' "$composer" 2>/dev/null && { echo charcoal; return; }
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
