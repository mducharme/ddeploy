#!/usr/bin/env bash
# PHP version management: install the FPM+CLI stack for a version on
# demand (idempotent), and provide a PATH shim so exec/composer hook
# steps run under the site's pinned PHP version rather than whatever
# `php` on PATH happens to default to.

SHIM_ROOT="$PROVISIONER_DIR/phpshim"

# Installs php<ver>-fpm plus every currently-configured PHP_EXTENSIONS
# package. Checks each package individually rather than just "is
# php<ver>-fpm present" — otherwise adding a new entry to
# PHP_EXTENSIONS (provisioner.conf) later never actually gets installed
# for a PHP version that's already provisioned, since the old check
# would short-circuit on the FPM package alone. ondrej/php packages
# imagick, redis, mongodb, apcu, xdebug, and most other common
# extensions the same way — add them here, not via pecl.
ensure_php_installed() {
    local ver="$1"
    local pkgs=("php${ver}-fpm")
    local ext
    for ext in $PHP_EXTENSIONS; do
        pkgs+=("php${ver}-${ext}")
    done

    local missing=() pkg
    for pkg in "${pkgs[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        log_info "installing ${missing[*]}"
        # < /dev/null: this can run mid-provision/deploy (a project
        # asking for a PHP version init's baseline loop didn't cover),
        # not just during init — see cmd_init.sh for why stdin must be
        # closed before installing a package that owns a running service
        # (here, php<ver>-fpm).
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" < /dev/null
    else
        log_info "php${ver}-fpm and configured extensions already installed"
    fi
    systemctl enable --now "php${ver}-fpm" >/dev/null 2>&1 || true
}

# Installs Composer once, globally, at /usr/local/bin/composer, using
# the official checksum-verified installer. Needs a `php` CLI to run the
# installer itself — uses php$DEFAULT_PHP, which is guaranteed present
# once the baseline PHP loop has run (PHP_EXTENSIONS always includes
# `cli`). Idempotent: does nothing if composer is already on PATH.
install_composer() {
    if command -v composer >/dev/null 2>&1; then
        log_info "composer already installed ($(composer --version 2>/dev/null))"
        return
    fi
    log_info "installing composer"
    local tmp; tmp="$(mktemp -d)"
    local expected actual
    expected="$(curl -fsS https://composer.github.io/installer.sig)"
    "php$DEFAULT_PHP" -r "copy('https://getcomposer.org/installer', '$tmp/composer-setup.php');"
    actual="$("php$DEFAULT_PHP" -r "echo hash_file('sha384', '$tmp/composer-setup.php');")"
    if [[ -z "$expected" || "$expected" != "$actual" ]]; then
        rm -rf "$tmp"
        die "composer installer checksum mismatch (or couldn't fetch the expected one) — aborting, nothing installed"
    fi
    "php$DEFAULT_PHP" "$tmp/composer-setup.php" --quiet --install-dir=/usr/local/bin --filename=composer
    rm -rf "$tmp"
    log_info "composer installed: $(composer --version)"
}

# Returns (on stdout) a directory to prepend to PATH so that `php` and
# `composer` inside it resolve to the pinned version — `composer` itself
# is a phar with a `php` shebang, and the shim makes that shebang
# resolve to the site's pinned version rather than whatever's default.
ensure_php_shim() {
    local ver="$1"
    local dir="$SHIM_ROOT/$ver"
    mkdir -p "$dir"
    [[ -L "$dir/php" ]] || ln -sf "/usr/bin/php${ver}" "$dir/php"
    if command -v composer >/dev/null 2>&1 && [[ ! -e "$dir/composer" ]]; then
        ln -sf "$(command -v composer)" "$dir/composer"
    fi
    echo "$dir"
}
