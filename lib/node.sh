#!/usr/bin/env bash
# Node toolchain + frontend builds. nvm manages the Node versions — one
# shared, root-owned install at $NVM_ROOT, never a per-user one:
#
#   - root is the only one that ever runs `nvm install` (it writes into
#     $NVM_ROOT: versions/, alias/, .cache/). A site's own www-<name> user
#     only ever gets a resolved versions/node/<ver>/bin on its PATH, which
#     is all `nvm use` itself does — so nothing site-side needs to source
#     nvm.sh, including queue workers and cron wrappers.
#   - nvm runs in a child `bash -c` with a scrubbed environment, never
#     sourced into this process: provision.sh runs under set -euo
#     pipefail, which nvm.sh isn't written for, and an inherited
#     NPM_CONFIG_PREFIX (or similar) would make nvm refuse to work.
#   - the version spec handed to nvm is always one ddeploy resolved and
#     validated itself (resolve_node_version_spec, lib/config.sh) — never
#     a bare `nvm install` in a release directory, which would have root
#     read a client-controlled .nvmrc through nvm's own parser.
#
# Pinned + commit-verified, same discipline as install_pinned_yq
# (lib/cmd_init.sh). v0.40.8 specifically: in older releases (confirmed
# in v0.40.4) nvm_download_artifact's checksum-mismatch branch was
# `|| ( rm ...; return 6 )` — a subshell, so the `return` never left the
# function and a tarball that failed its SHASUMS256 check was extracted
# and installed anyway. v0.40.8 uses `|| { ...; return 6; }`. Don't pin
# anything older. Bump both values together, from the tag's own peeled
# commit (`git ls-remote --tags https://github.com/nvm-sh/nvm.git`, the
# `^{}` line).
NVM_TAG="v0.40.8"
NVM_COMMIT="a885b885fef16fac4bc544188fb25e9e37ae83e8"

# Node 25+ no longer bundles corepack; installed per Node version, as
# root, into that version's own prefix. pnpm/yarn always go through
# corepack, which honors (and hash-checks) a package.json
# `packageManager` field.
COREPACK_VERSION="0.36.0"

# Runs `nvm "$@"` as root in a clean child shell. Output goes wherever
# the caller sends it — callers that capture stdout redirect installs
# to stderr themselves.
nvm_cmd() {
    env -i HOME=/root PATH=/usr/local/bin:/usr/bin:/bin \
        NVM_DIR="$NVM_ROOT" NVM_NO_PROGRESS=1 NVM_NO_SOURCE_FALLBACK=1 \
        bash -c '. "$NVM_DIR/nvm.sh" --no-use && nvm "$@"' _ "$@"
}

# Clones (or moves an existing clone to) nvm at $NVM_TAG, then refuses
# to continue unless HEAD is exactly $NVM_COMMIT. Idempotent. Installed
# Node versions under $NVM_ROOT/versions are untracked by nvm's own
# .gitignore and survive a re-checkout.
install_nvm() {
    local head
    head="$(git -C "$NVM_ROOT" rev-parse HEAD 2>/dev/null || true)"
    if [[ -f "$NVM_ROOT/nvm.sh" && "$head" == "$NVM_COMMIT" ]]; then
        log_info "nvm $NVM_TAG already installed at $NVM_ROOT"
    else
        if [[ -d "$NVM_ROOT/.git" ]]; then
            log_info "moving nvm at $NVM_ROOT to $NVM_TAG"
            git -C "$NVM_ROOT" fetch --quiet --depth 1 origin "refs/tags/$NVM_TAG:refs/tags/$NVM_TAG" \
                || die "failed to fetch nvm $NVM_TAG"
            git -C "$NVM_ROOT" -c advice.detachedHead=false checkout --quiet "$NVM_COMMIT" \
                || die "failed to check out nvm $NVM_COMMIT"
        else
            [[ -e "$NVM_ROOT" ]] && die "$NVM_ROOT exists but isn't an nvm git checkout — move it aside (or point NVM_ROOT elsewhere) and re-run init"
            log_info "installing nvm $NVM_TAG at $NVM_ROOT"
            git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$NVM_TAG" \
                https://github.com/nvm-sh/nvm.git "$NVM_ROOT" \
                || die "failed to clone nvm $NVM_TAG"
        fi
        head="$(git -C "$NVM_ROOT" rev-parse HEAD 2>/dev/null || true)"
        [[ "$head" == "$NVM_COMMIT" ]] \
            || die "nvm $NVM_TAG at $NVM_ROOT is commit '$head', expected $NVM_COMMIT — refusing to use it (a moved tag or a tampered mirror both look like this)"
    fi
    # Readable + traversable by every site user (they execute
    # versions/node/*/bin/*), writable by root only.
    chown -R root:root "$NVM_ROOT"
    chmod 755 "$NVM_ROOT"
    ensure_traversable "$NVM_ROOT"
}

node_bin_dir() { echo "$NVM_ROOT/versions/node/$1/bin"; }

# $1 a validated version spec ("22", "22.11.0", "lts/*", ...). Installs
# it if nothing installed matches (a major-only spec resolves to the
# newest installed patch of that major, so an ordinary deploy never
# re-downloads — `init` is what refreshes patch releases). Prints the
# exact installed version (vX.Y.Z). Returns nonzero instead of dying:
# this runs inside $(...), where die would only exit the subshell anyway.
ensure_node_installed() {
    local spec="$1" ver
    if [[ ! -f "$NVM_ROOT/nvm.sh" ]]; then
        log_error "nvm not found at $NVM_ROOT — run 'provision.sh init'"
        return 1
    fi
    ver="$(nvm_cmd version "$spec" 2>/dev/null || true)"
    if [[ ! "$ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_info "installing node $spec (nvm)"
        nvm_cmd install -b "$spec" >&2 || { log_error "nvm install $spec failed"; return 1; }
        ver="$(nvm_cmd version "$spec" 2>/dev/null || true)"
        [[ "$ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { log_error "node $spec still not resolvable after install"; return 1; }
    fi
    ensure_corepack "$ver" || return 1
    printf '%s\n' "$ver"
}

# `init`: install/refresh a baseline spec to its newest release — the
# only place a patch upgrade of an already-installed major happens.
refresh_node_version() {
    local spec="$1" ver
    nvm_cmd install -b "$spec" >&2 || die "nvm install $spec failed"
    ver="$(nvm_cmd version "$spec")"
    ensure_corepack "$ver" || die "corepack setup for node $ver failed"
    log_info "node $spec -> $ver"
}

# Makes pnpm/yarn resolvable (as corepack shims) from $1's own bin dir.
ensure_corepack() {
    local ver="$1"
    local bin; bin="$(node_bin_dir "$ver")"
    [[ -x "$bin/node" ]] || { log_error "node $ver is not installed under $NVM_ROOT"; return 1; }
    if [[ ! -x "$bin/corepack" ]]; then
        log_info "node $ver ships without corepack — installing corepack@$COREPACK_VERSION into it"
        env -i HOME=/root PATH="$bin:/usr/bin:/bin" \
            npm install -g --no-audit --no-fund "corepack@$COREPACK_VERSION" >&2 \
            || { log_error "installing corepack for node $ver failed"; return 1; }
    fi
    if [[ ! -e "$bin/pnpm" || ! -e "$bin/yarn" ]]; then
        env -i HOME=/root PATH="$bin:/usr/bin:/bin" corepack enable pnpm yarn >&2 \
            || { log_error "corepack enable failed for node $ver"; return 1; }
    fi
}

# Resolves NODE_VERSION_SPEC (set by parse_config) to an installed
# toolchain, setting NODE_VERSION (vX.Y.Z) and NODE_BIN. Cached per
# spec, so each caller in the same deploy (replay_hooks, run_repo_hook,
# queue workers, schedule) can call it unconditionally. A failure is
# fatal only when this site actually needs Node (a build step, or a
# version it declared itself) — a PHP-only site riding on DEFAULT_NODE
# just deploys without Node on its PATH, with a warning.
prepare_site_node() {
    local name="$1"
    if [[ "$NODE_ENABLED" != "true" || -z "${NODE_VERSION_SPEC:-}" ]]; then
        NODE_BIN=""; NODE_VERSION=""
        return 0
    fi
    [[ -n "${NODE_BIN:-}" && "${NODE_BIN_SPEC:-}" == "$NODE_VERSION_SPEC" ]] && return 0
    local ver
    if ! ver="$(ensure_node_installed "$NODE_VERSION_SPEC")"; then
        NODE_BIN=""; NODE_VERSION=""
        if [[ "${BUILD_ENABLED:-false}" == "true" || "${NODE_VERSION_SOURCE:-default}" != "default" ]]; then
            die "'$name': node $NODE_VERSION_SPEC (from $NODE_VERSION_SOURCE) could not be installed — see above"
        fi
        log_warn "'$name': default node $NODE_VERSION_SPEC could not be installed — continuing without node on PATH"
        return 0
    fi
    NODE_VERSION="$ver"
    NODE_BIN="$(node_bin_dir "$ver")"
    NODE_BIN_SPEC="$NODE_VERSION_SPEC"
}

# PATH for anything run as a site user: pinned PHP shim, then the site's
# resolved Node (if any), then the system.
toolchain_path() {
    local shim; shim="$(ensure_php_shim "$1")"
    printf '%s%s:/usr/bin:/bin\n' "$shim" "${NODE_BIN:+:$NODE_BIN}"
}

# $1 package.json dir. Prints npm|pnpm|yarn, or returns 2 for a package
# manager ddeploy doesn't support (bun). Explicit build.package_manager
# wins, then package.json's packageManager field, then the lockfile;
# no lockfile at all falls back to npm (pm_install_cmd then refuses).
detect_package_manager() {
    local d="$1" field
    if [[ -n "${BUILD_PACKAGE_MANAGER:-}" && "$BUILD_PACKAGE_MANAGER" != "auto" ]]; then
        echo "$BUILD_PACKAGE_MANAGER"
        return 0
    fi
    field="$(yq -p json eval '.packageManager // ""' "$d/package.json" 2>/dev/null || true)"
    case "$field" in
        npm@*|pnpm@*|yarn@*) echo "${field%%@*}"; return 0 ;;
        bun@*) return 2 ;;
    esac
    if [[ -f "$d/pnpm-lock.yaml" ]]; then echo pnpm
    elif [[ -f "$d/yarn.lock" ]]; then echo yarn
    elif [[ -f "$d/package-lock.json" || -f "$d/npm-shrinkwrap.json" ]]; then echo npm
    elif [[ -f "$d/bun.lock" || -f "$d/bun.lockb" ]]; then return 2
    else echo npm
    fi
}

# Any lockfile a supported package manager would install from.
has_node_lockfile() {
    local d="$1"
    [[ -f "$d/package-lock.json" || -f "$d/npm-shrinkwrap.json" || -f "$d/pnpm-lock.yaml" || -f "$d/yarn.lock" ]]
}

# $1 package manager, $2 package.json dir. Prints the lockfile-exact
# install command, or returns 3 when the matching lockfile is missing —
# a build that resolves fresh versions on every deploy isn't one a
# rollback can reproduce, so it's refused rather than guessed at.
pm_install_cmd() {
    local pm="$1" d="$2"
    case "$pm" in
        npm)
            [[ -f "$d/package-lock.json" || -f "$d/npm-shrinkwrap.json" ]] || return 3
            echo "npm ci --no-audit --no-fund"
            ;;
        pnpm)
            [[ -f "$d/pnpm-lock.yaml" ]] || return 3
            echo "pnpm install --frozen-lockfile"
            ;;
        yarn)
            [[ -f "$d/yarn.lock" ]] || return 3
            # Berry (2+) marks its lockfile with __metadata and usually
            # has .yarnrc.yml; classic uses --frozen-lockfile instead.
            if [[ -f "$d/.yarnrc.yml" ]] || grep -q '^__metadata:' "$d/yarn.lock" 2>/dev/null; then
                echo "yarn install --immutable"
            else
                echo "yarn install --frozen-lockfile --non-interactive"
            fi
            ;;
        *) return 1 ;;
    esac
}

# --- last build result, for `doctor` -------------------------------------

build_state_path() { echo "$GENERATED_DIR/$1.build-state"; }

# $1 name $2 ok|failed $3 detail. One line, overwritten each build:
# status<TAB>unix time<TAB>node version<TAB>detail.
record_build_state() {
    mkdir -p "$GENERATED_DIR"
    printf '%s\t%s\t%s\t%s\n' "$2" "$(date +%s)" "${NODE_VERSION:-?}" "$3" > "$(build_state_path "$1")"
}

# --- node_modules reuse ------------------------------------------------
#
# Every forward release starts from a fresh clone, and `npm ci` deletes
# node_modules before installing anyway, so a warm package cache alone
# still means a full install every deploy. Instead, after a successful
# build, node_modules is moved (not deleted) into a root-only slot per
# site + build path, keyed on everything that determines its contents.
# The next deploy with an identical key moves it straight back and skips
# the install. A mismatch (lockfile/package.json/Node/package manager
# changed) does a normal install. The slot is root:root 700 between
# deploys, so the site's own user can't tamper with it in the meantime.
# Same filesystem as the releases, so both moves are renames.

node_modules_cache_root() { echo "$SITES_ROOT/.node-modules-cache"; }

node_modules_slot() {
    local name="$1" path="${2:-.}"
    local slot="${path%/}"
    slot="${slot//\//__}"
    echo "$(node_modules_cache_root)/$name/${slot:-.}"
}

# $1 package.json dir, $2 package manager, $3 install command. Prints a
# sha256 over what decides node_modules' contents.
node_modules_key() {
    local d="$1" pm="$2" install="$3" f
    {
        printf '%s\n%s\n%s\n%s\n' "$NODE_VERSION" "$pm" "$install" "$(dpkg --print-architecture 2>/dev/null)"
        # `if`, not `[[ ]] && ...`: under pipefail a false last test would
        # fail this whole pipeline, and set -e would silently end the deploy.
        for f in package.json package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock \
                 .npmrc .yarnrc .yarnrc.yml pnpm-workspace.yaml; do
            if [[ -f "$d/$f" ]]; then
                printf '== %s\n' "$f"
                cat "$d/$f"
            fi
        done
    } | sha256sum | cut -d' ' -f1
}

# Moves a cached node_modules into $3 if $4 matches its key. Returns 0 on
# a hit (install can be skipped).
restore_node_modules() {
    local name="$1" path="$2" bdir="$3" key="$4"
    local slot; slot="$(node_modules_slot "$name" "$path")"
    [[ -d "$slot/node_modules" && -f "$slot/key" ]] || return 1
    [[ "$(<"$slot/key")" == "$key" ]] || return 1
    rm -rf "$bdir/node_modules"
    mv "$slot/node_modules" "$bdir/node_modules" || return 1
    rm -f "$slot/key"
    return 0
}

# Moves $3/node_modules into the cache slot under key $4 (replacing
# whatever was there). No node_modules (yarn PnP, say) = nothing cached.
stash_node_modules() {
    local name="$1" path="$2" bdir="$3" key="$4"
    [[ -d "$bdir/node_modules" ]] || return 0
    local root; root="$(node_modules_cache_root)"
    local slot; slot="$(node_modules_slot "$name" "$path")"
    mkdir -p "$slot"
    chown root:root "$root" "$root/$name" "$slot"
    chmod 700 "$root"
    rm -rf "$slot/node_modules" "$slot/key"
    mv "$bdir/node_modules" "$slot/node_modules"
    printf '%s\n' "$key" > "$slot/key"
}

# `remove`/`remove-preview`: derived data only, always safe to drop.
remove_node_modules_cache() {
    rm -rf "$(node_modules_cache_root)/$1"
}

# NODE_BUILD_MEMORY_MAX ("2G", "1536M") -> MiB, for --max-old-space-size.
# Empty if unparseable or unset.
memory_max_mib() {
    local v="$1"
    [[ "$v" =~ ^([0-9]+)([KMGkmg]?)$ ]] || return 0
    local n="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]^^}"
    case "$unit" in
        G) echo $((n * 1024)) ;;
        M) echo "$n" ;;
        K) echo $((n / 1024)) ;;
        "") echo $((n / 1024 / 1024)) ;;
    esac
}

# $1 exec user, then env assignments, then "--", then the shell command.
# Runs as the site user under a memory-capped transient systemd scope
# (so an out-of-memory webpack/vite build kills only itself, not
# php-fpm or MariaDB on a small box) and a hard timeout.
run_build_cmd() {
    local exec_user="$1"; shift
    local -a envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
    shift
    local cmd="$1"
    local -a wrap=()
    if [[ -n "$NODE_BUILD_MEMORY_MAX" && -d /run/systemd/system ]] && command -v systemd-run >/dev/null 2>&1; then
        wrap=(systemd-run --scope --quiet --collect -p "MemoryMax=$NODE_BUILD_MEMORY_MAX" -p MemorySwapMax=0 --)
    fi
    # </dev/null: runs inside replay_hooks' `while read ... < steps` loop,
    # whose remaining steps would otherwise be this command's stdin.
    # Output goes to BUILD_OUT too (set by run_node_build), so a failure
    # can put its last lines in the site log (build_failed).
    run_captured "${BUILD_OUT:-/dev/null}" "${wrap[@]}" timeout --kill-after=30 "$NODE_BUILD_TIMEOUT" \
        sudo -u "$exec_user" env "${envs[@]}" bash -lc "$cmd" </dev/null
}

# The `node` deploy step (lib/hooks.sh). Reads the BUILD_* globals
# parse_config set for this site. $1 name, $2 release/checkout dir,
# $3 exec user, $4 HOME, $5 PATH.
run_node_build() {
    local name="$1" dir="$2" exec_user="$3" exec_home="$4" path="$5"
    [[ -n "${NODE_BIN:-}" ]] || die "'$name': build step needs node, but no node toolchain is available (NODE_ENABLED=$NODE_ENABLED)"

    local bdir="$dir"
    [[ -n "$BUILD_PATH" && "$BUILD_PATH" != "." ]] && bdir="$dir/${BUILD_PATH%/}"
    [[ -f "$bdir/package.json" ]] || die "'$name': no package.json in build path '${BUILD_PATH:-.}'"

    local pm rc=0
    pm="$(detect_package_manager "$bdir")" || rc=$?
    [[ "$rc" -eq 0 ]] || die "'$name': bun isn't supported — use npm, pnpm, or yarn (or set build.package_manager)"

    local mib; mib="$(memory_max_mib "$NODE_BUILD_MEMORY_MAX")"
    local -a base_env=(
        HOME="$exec_home" PATH="$path" SSH_AUTH_SOCK="${DEPLOY_SSH_AUTH_SOCK:-}"
        CI=true COREPACK_ENABLE_DOWNLOAD_PROMPT=0
    )
    # Headroom under the cgroup cap for everything that isn't V8's heap.
    [[ -n "$mib" && "$mib" -gt 512 ]] && base_env+=(NODE_OPTIONS="--max-old-space-size=$((mib * 3 / 4))")

    local started=$SECONDS
    BUILD_OUT="$(mktemp)"
    log_info "node build ($name, node $NODE_VERSION, $pm, path '${BUILD_PATH:-.}')"
    site_log "$name" "deploy: node build: node=$NODE_VERSION pm=$pm path=${BUILD_PATH:-.}"

    # Reuse only makes sense when ddeploy both installs and discards
    # node_modules itself.
    local reuse=0 key="" install=""
    if [[ "$BUILD_INSTALL" == "true" ]]; then
        if ! install="$(pm_install_cmd "$pm" "$bdir")"; then
            record_build_state "$name" failed "no lockfile for $pm"
            die "'$name': no lockfile for $pm in '${BUILD_PATH:-.}' — commit one (ddeploy only installs lockfile-exact dependencies), or set build.install: false"
        fi
        if [[ "$NODE_REUSE_MODULES" == "true" && "$BUILD_KEEP_NODE_MODULES" != "true" ]]; then
            reuse=1
            key="$(node_modules_key "$bdir" "$pm" "$install")"
        fi
        if [[ "$reuse" -eq 1 ]] && restore_node_modules "$name" "${BUILD_PATH:-.}" "$bdir" "$key"; then
            log_info "  reusing node_modules from the last build (lockfile, package.json, node and $pm unchanged) — skipping install"
        else
            log_info "  $install"
            # No NODE_ENV here, even when build.env sets one:
            # NODE_ENV=production makes npm/pnpm/yarn skip devDependencies
            # — which is exactly where vite/webpack/tailwind live.
            run_build_cmd "$exec_user" "${base_env[@]}" -- "cd '$bdir' && $install" \
                || build_failed "$name" "$?" "dependency install"
        fi
    fi

    local run="$BUILD_COMMAND"
    [[ -n "$run" ]] || run="$pm run $BUILD_SCRIPT"
    local -a build_env=("${base_env[@]}")
    local has_node_env=0 e
    for e in "${BUILD_ENV[@]}"; do
        [[ "${e%%=*}" == "NODE_ENV" ]] && has_node_env=1
        build_env+=("$e")
    done
    [[ "$has_node_env" -eq 1 ]] || build_env+=(NODE_ENV=production)
    log_info "  $run"
    run_build_cmd "$exec_user" "${build_env[@]}" -- "cd '$bdir' && $run" \
        || build_failed "$name" "$?" "build"

    local out
    for out in "${BUILD_OUTPUTS[@]}"; do
        out="${out%/}"
        if [[ -d "$dir/$out" ]]; then
            if [[ -z "$(ls -A "$dir/$out" 2>/dev/null)" ]]; then
                record_build_state "$name" failed "output '$out' empty"
                die "'$name': build output '$out' is an empty directory"
            fi
        elif [[ ! -f "$dir/$out" ]]; then
            record_build_state "$name" failed "output '$out' missing"
            die "'$name': build output '$out' is missing after the build"
        fi
    done

    if [[ "$BUILD_KEEP_NODE_MODULES" != "true" ]]; then
        if [[ "$reuse" -eq 1 ]]; then
            stash_node_modules "$name" "${BUILD_PATH:-.}" "$bdir" "$key"
        fi
        rm -rf "$bdir/node_modules"
    fi
    rm -f "$BUILD_OUT"
    local took=$((SECONDS - started))
    log_info "node build done in ${took}s"
    site_log "$name" "deploy: node build ok in ${took}s"
    record_build_state "$name" ok "$pm, ${took}s"
}

build_failed() {
    local name="$1" rc="$2" what="$3" hint=""
    case "$rc" in
        124|137) hint=" — killed: hit NODE_BUILD_TIMEOUT (${NODE_BUILD_TIMEOUT}s) or NODE_BUILD_MEMORY_MAX ($NODE_BUILD_MEMORY_MAX)" ;;
    esac
    site_log "$name" "deploy: node $what FAILED (exit $rc)$hint"
    site_log_output "$name" "${BUILD_OUT:-}"
    rm -f "${BUILD_OUT:-}"
    record_build_state "$name" failed "$what exit $rc"
    die "'$name': node $what failed (exit $rc)$hint"
}
