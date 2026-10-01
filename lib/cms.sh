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
# Every CMS gets the same composer default (DEFAULT_COMPOSER_INSTALL,
# lib/config.sh).
cms_defaults() {
    local cms="$1"
    CMS_DOCROOT=""
    CMS_COMPOSER_ARGS="$DEFAULT_COMPOSER_INSTALL"
    CMS_MIGRATE_CMD=""
    CMS_CACHE_CMD=""
    CMS_DB_ENV_SCHEME="laravel"

    case "$cms" in
        craftcms)
            CMS_DOCROOT="web"
            CMS_MIGRATE_CMD="php craft migrate/all --interactive=0 && php craft project-config/apply --force"
            CMS_CACHE_CMD="php craft clear-caches/all"
            CMS_DB_ENV_SCHEME="craft"
            ;;
        wordpress-bedrock)
            CMS_DOCROOT="web"
            CMS_DB_ENV_SCHEME="laravel"
            ;;
        wordpress)
            CMS_DOCROOT=""
            CMS_DB_ENV_SCHEME="none"
            ;;
        charcoal)
            CMS_DOCROOT="www"
            CMS_DB_ENV_SCHEME="charcoal"
            ;;
    esac
}

# Fills in the non-DB .env variables a CMS refuses to boot without, so a
# first provision serves a page instead of a 500. Only ever adds keys
# that are missing — never overwrites a value an operator (or a previous
# run) already set, so it's safe on every provision. Keyed off
# DB_ENV_SCHEME rather than detect_cms: that's the setting that already
# decided this site's .env is in that CMS's format. Values that are
# secrets are never logged, only the key names.
# $1 name, $2 site dir (.env at its root), $3 scheme, $4 site URL.
seed_cms_env() {
    local name="$1" dir="$2" scheme="$3" url="$4"
    local env_file="$dir/.env"
    local -a added=()

    case "$scheme" in
        craft)
            [[ -e "$env_file" ]] || return 0
            if [[ -z "$(read_env_var "$env_file" CRAFT_APP_ID || true)" ]]; then
                write_env_var "$env_file" CRAFT_APP_ID "CraftCMS--$(cat /proc/sys/kernel/random/uuid)"
                added+=(CRAFT_APP_ID)
            fi
            if [[ -z "$(read_env_var "$env_file" CRAFT_SECURITY_KEY || true)" ]]; then
                write_env_var "$env_file" CRAFT_SECURITY_KEY "$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
                added+=(CRAFT_SECURITY_KEY)
            fi
            if [[ -z "$(read_env_var "$env_file" CRAFT_ENVIRONMENT || true)" ]]; then
                write_env_var "$env_file" CRAFT_ENVIRONMENT "staging"
                added+=(CRAFT_ENVIRONMENT)
            fi
            if [[ -z "$(read_env_var "$env_file" PRIMARY_SITE_URL || true)" ]]; then
                write_env_var "$env_file" PRIMARY_SITE_URL "$url"
                added+=(PRIMARY_SITE_URL)
            fi
            ;;
        *) return 0 ;;
    esac

    [[ "${#added[@]}" -gt 0 ]] || return 0
    log_info "'$name': added missing .env keys: ${added[*]} (values not logged — see 'ddeploy env $name --show')"
    if [[ " ${added[*]} " == *" CRAFT_SECURITY_KEY "* ]]; then
        log_warn "'$name': generated a fresh CRAFT_SECURITY_KEY — if you import a database from another environment, set that environment's key instead ('ddeploy env $name CRAFT_SECURITY_KEY=...') or anything Craft encrypted won't decrypt"
    fi
}
