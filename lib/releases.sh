#!/usr/bin/env bash
# Atomic releases for normal (non-preview) sites: $SITES_ROOT/<name>/ is a
# wrapper containing releases/<timestamp>-<sha>/ working trees and a
# `current` symlink nginx/php-fpm follow. Persistent files already live
# outside the checkout (lib/persistent.sh); this is the code-side half of
# the same Capistrano/Trellis shape.
#
# Previews stay in-place — they fetch+reset --hard because PR branches
# rebase, and there's nothing to roll back to. See cmd_preview.sh.
#
# A failed deploy (pull, hooks) never retargets `current`, so the previous
# tree stays live. Rollback retargets `current` at an earlier release
# when one is still on disk; otherwise it builds a new release from
# `git reset --hard` (the objects are still in current's .git).

release_id() {
    printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "${1:0:12}"
}

# --- deploy_branch: which branch a normal site tracks, set by the
# operator (`provision --branch`, or the manifest's 3rd column) — never
# read from the client repo itself. A repo-committed setting would have
# to be pushed to whatever branch is CURRENTLY tracked to ever be seen
# (the branch you're trying to move away from), which is backwards; an
# operator-side file has no such bootstrapping problem; see README
# "Default branch". ---

deploy_branch_file() { echo "$GENERATED_DIR/$1.deploy-branch"; }

write_deploy_branch() {
    local name="$1" branch="$2"
    validate_branch_name "$branch" "--branch for '$name'"
    mkdir -p "$GENERATED_DIR"
    printf '%s\n' "$branch" > "$(deploy_branch_file "$name")"
}

clear_deploy_branch() { rm -f "$(deploy_branch_file "$1")"; }

# Empty if no override is set. A present-but-malformed value dies via
# validate_branch_name rather than being silently ignored, so a typo
# surfaces immediately instead of quietly deploying the wrong branch.
read_deploy_branch() {
    local name="$1" f; f="$(deploy_branch_file "$name")"
    [[ -s "$f" ]] || return 0
    local val; val="$(<"$f")"
    val="${val%$'\n'}"
    [[ -n "$val" ]] && validate_branch_name "$val" "deploy_branch override for '$name'"
    printf '%s' "$val"
}

# site_root is the site user's HOME (composer cache, .ssh) but must not
# let that user replace `current` (a compromised pool would otherwise
# retarget nginx at an attacker-controlled tree). Sticky bit: the user
# can create ~/.composer, cannot unlink root-owned current.
lock_site_root() {
    local name="$1"
    local root; root="$(site_root "$name")"
    mkdir -p "$root/releases"
    if id -u "www-$name" >/dev/null 2>&1; then
        chown root:"www-$name" "$root"
        chmod 1775 "$root"
    fi
    chown root:root "$root/releases"
    chmod 755 "$root/releases"
    if [[ -L "$root/current" ]]; then
        chown -h root:root "$root/current" 2>/dev/null || true
    fi
}

# Atomically point current at $2 (an absolute path under releases/).
switch_current() {
    local name="$1" dest="$2"
    local root; root="$(site_root "$name")"
    local rel="releases/$(basename "$dest")"
    [[ -d "$root/$rel" ]] || die "release '$dest' is not under $root/releases"
    ln -sfn "$rel" "$root/.current-new"
    mv -Tf "$root/.current-new" "$root/current"
    chown -h root:root "$root/current" 2>/dev/null || true
    git_trust_repo "$root/current"
    git_trust_repo "$dest"
}

# Promote a legacy in-place git checkout (the pre-atomic layout) to
# releases/current. No-op if already migrated, or if this isn't a git
# tree (previews, empty dir). Called from provision and deploy.
ensure_releases_layout() {
    local name="$1"
    local root; root="$(site_root "$name")"
    [[ -d "$root" ]] || return 0
    if is_releases_layout "$name"; then
        git_trust_repo "$root/current"
        local real; real="$(current_release_real "$name")"
        [[ -n "$real" ]] && git_trust_repo "$real"
        lock_site_root "$name"
        return 0
    fi
    if type is_preview >/dev/null 2>&1 && is_preview "$name"; then
        return 0
    fi
    [[ -d "$root/.git" ]] || return 0

    git_trust_repo "$root"
    local sha; sha="$(git -C "$root" log -1 --format=%H)"
    local id; id="$(release_id "$sha")"
    local tmp; tmp="$(mktemp -d /tmp/ddeploy-migrate-XXXXXX)"
    mv "$root" "$tmp/checkout"
    mkdir -p "$root/releases"
    mv "$tmp/checkout" "$root/releases/$id"
    rm -rf "$tmp"
    if [[ -d "$root/releases/$id/.ssh" ]]; then
        mv "$root/releases/$id/.ssh" "$root/.ssh"
    fi
    switch_current "$name" "$root/releases/$id"
    lock_site_root "$name"

    # Without this, nginx's ON-DISK vhost still has the pre-migration
    # absolute path (.../<name>/<docroot>) baked in from the last time
    # install_vhost ran under the old flat-checkout layout — and that
    # path no longer exists (the content just moved under releases/), so
    # EVERY request 404s from this point until the caller's own later
    # parse_config/install_vhost call happens to run, which can be tens
    # of seconds to minutes away (hook replay runs in between). Bridge
    # that gap immediately: re-render the vhost against the exact config
    # this release was already serving successfully a moment ago — no
    # content or behavior changes, just repointing nginx's root at the
    # new, symlink-based path right away. The caller's normal
    # parse_config + install_vhost further down still runs afterward and
    # may re-render again with fresh values (a config change picked up
    # in the same deploy); this only closes the migration-only gap.
    if ! (
        mig_cfg="$(resolve_config_path "$name")"
        [[ -n "$mig_cfg" ]] || exit 1
        parse_config "$name" "$mig_cfg" 1
        mig_root="$root/current"
        [[ -n "$DOCROOT" ]] && mig_root="$mig_root/$DOCROOT"
        install_vhost "$name" "$mig_root" "${BASIC_AUTH_CONFIG:-$BASIC_AUTH_DEFAULT}" \
            "${CLIENT_MAX_BODY_SIZE_CONFIG:-$CLIENT_MAX_BODY_SIZE}" "${ADDITIONAL_HOSTNAMES[@]}"
        if [[ "${#ADDITIONAL_FQDNS[@]}" -gt 0 ]]; then
            # Same as provision/deploy's own handling of this call: a
            # custom domain's cert already exists in the normal case
            # being bridged here (the site was already live), so this
            # is almost always a no-op re-render, not a fresh HTTP-01
            # request — but don't let a DNS/cert hiccup here fail the
            # whole bridge and lose the main-vhost fix that already
            # landed above.
            install_custom_domain_vhost "$name" "$mig_root" "${BASIC_AUTH_CONFIG:-$BASIC_AUTH_DEFAULT}" \
                "${CLIENT_MAX_BODY_SIZE_CONFIG:-$CLIENT_MAX_BODY_SIZE}" "${ADDITIONAL_FQDNS[@]}" || true
        fi
    ); then
        log_warn "'$name': could not immediately re-point the vhost at the migrated release — it will 404 until this deploy/provision finishes and re-renders it"
    fi
    log_info "migrated '$name' to releases layout ($root/releases/$id)"
}

# Rename a staging clone to releases/<timestamp>-<sha>. Prints the final path.
finalize_staging() {
    local staging="$1"
    local sha; sha="$(git -C "$staging" log -1 --format=%H)"
    local parent; parent="$(dirname "$staging")"
    local id dest n=0
    id="$(release_id "$sha")"
    dest="$parent/$id"
    while [[ -e "$dest" ]]; do
        n=$((n + 1))
        dest="$parent/${id}-$n"
    done
    mv "$staging" "$dest"
    git_trust_repo "$dest"
    printf '%s\n' "$dest"
}

# First clone of a site: origin -> a new release dir. Does not switch
# current. $3, if given, clones that branch directly — the operator's own
# --branch at provision time (README "Default branch"), which
# cmd_provision.sh also persists via write_deploy_branch so later deploys
# stay pinned to it without needing a second call.
clone_into_release() {
    local name="$1" repo_url="$2" branch="${3:-}"
    local root; root="$(site_root "$name")"
    mkdir -p "$root/releases"
    rm -rf "$root/releases"/.staging-*
    local staging="$root/releases/.staging-$$"
    rm -rf "$staging"
    local -a branch_args=()
    if [[ -n "$branch" ]]; then
        validate_branch_name "$branch" "--branch for '$name'"
        branch_args=(--branch "$branch")
        log_info "cloning $repo_url (branch $branch) -> $root"
    else
        log_info "cloning $repo_url -> $root"
    fi
    GIT_SSH_COMMAND="$(git_ssh_command)" git clone "${branch_args[@]}" "$repo_url" "$staging" \
        || die "git clone failed for '$name'"
    git_trust_repo "$staging"
    finalize_staging "$staging"
}

# Next forward deploy: clone the live tree (local, fast), restore origin
# to the real remote (git clone of a path would otherwise set origin to
# that path), pull --ff-only as the site user. Prints the new release
# path. Leaves current untouched; caller switches after hooks succeed.
prepare_forward_release() {
    local name="$1"
    local root; root="$(site_root "$name")"
    local live; live="$(current_release_real "$name")"
    [[ -d "$live/.git" ]] || die "$root/current is not a git repo — provision it first"
    git_trust_repo "$live"

    local origin; origin="$(git -C "$live" remote get-url origin)"
    [[ -n "$origin" ]] || die "no origin remote on '$name'"

    mkdir -p "$root/releases"
    rm -rf "$root/releases"/.staging-*
    local staging="$root/releases/.staging-$$"
    rm -rf "$staging"
    # Local clone as root of a www-<name>-owned tree. safe.directory=*
    # is scoped to this one invocation — root is this tool's operator.
    git -c safe.directory='*' clone --quiet "$live" "$staging" \
        || die "failed to clone the live release of '$name' into a new staging directory"
    git_trust_repo "$staging"
    git -C "$staging" remote set-url origin "$origin" \
        || die "failed to restore origin on the new release of '$name'"
    apply_permissions "$name" "$staging"

    # deploy_branch (README "Default branch") is operator state, not
    # anything read from the repo — available immediately, no pull
    # needed to see it. Checked before pulling: if we're about to switch
    # away from the currently-tracked branch anyway, there's no reason to
    # pull --ff-only it first (and every reason not to — that pull could
    # itself fail non-fast-forward on a branch we're abandoning regardless).
    local target_branch; target_branch="$(read_deploy_branch "$name")"
    local current_branch; current_branch="$(git -C "$staging" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

    if [[ -n "$target_branch" && "$target_branch" != "$current_branch" ]]; then
        log_info "'$name': switching to configured deploy_branch '$target_branch' (was '$current_branch')"
        if ! sudo -u "www-$name" env HOME="$root" git -C "$staging" fetch --quiet origin "$target_branch" 2>&1 | tee -a "$LOG_DIR/$name.log" >&2; then
            rm -rf "$staging"
            die "'$name': failed to fetch deploy_branch '$target_branch' from origin — check the branch exists"
        fi
        if ! sudo -u "www-$name" env HOME="$root" git -C "$staging" checkout -B "$target_branch" "origin/$target_branch" 2>&1 | tee -a "$LOG_DIR/$name.log" >&2; then
            rm -rf "$staging"
            die "'$name': failed to switch to deploy_branch '$target_branch'"
        fi
    else
        log_info "git pull --ff-only ($name)"
        if ! sudo -u "www-$name" env HOME="$root" git -C "$staging" pull --ff-only 2>&1 | tee -a "$LOG_DIR/$name.log" >&2; then
            rm -rf "$staging"
            die "git pull --ff-only failed for '$name' — live tree left unchanged"
        fi
    fi
    finalize_staging "$staging"
}

# Prints the on-disk release whose HEAD is $2, if any.
find_release_for_sha() {
    local name="$1" want="$2"
    local rels; rels="$(site_root "$name")/releases"
    [[ -d "$rels" ]] || return 1
    local d head
    for d in "$rels"/*/; do
        [[ -d "${d}.git" || -d "$d/.git" ]] || continue
        d="${d%/}"
        git_trust_repo "$d"
        head="$(git -C "$d" rev-parse HEAD 2>/dev/null || true)"
        [[ "$head" == "$want" ]] && { printf '%s\n' "$d"; return 0; }
    done
    return 1
}

# Rollback: reuse an existing release at $2, or clone current and
# reset --hard. Prints the dest path. $3 is set to "existing" or "new"
# via nameref-style global ROLLBACK_RELEASE_KIND for the caller.
prepare_rollback_release() {
    local name="$1" target="$2"
    local live; live="$(current_release_real "$name")"
    [[ -d "$live/.git" ]] || die "$(site_root "$name")/current is not a git repo — provision it first"
    git_trust_repo "$live"

    local want
    want="$(git -C "$live" rev-parse --verify "${target}^{commit}" 2>/dev/null)" \
        || die "'$target' isn't a commit '$name's checkout knows about"

    local existing
    if existing="$(find_release_for_sha "$name" "$want")"; then
        ROLLBACK_RELEASE_KIND="existing"
        printf '%s\n' "$existing"
        return 0
    fi

    ROLLBACK_RELEASE_KIND="new"
    local root; root="$(site_root "$name")"
    local origin; origin="$(git -C "$live" remote get-url origin)"
    rm -rf "$root/releases"/.staging-*
    local staging="$root/releases/.staging-$$"
    rm -rf "$staging"
    git -c safe.directory='*' clone --quiet "$live" "$staging" \
        || die "failed to clone the live release of '$name' for rollback"
    git_trust_repo "$staging"
    [[ -n "$origin" ]] && git -C "$staging" remote set-url origin "$origin"
    apply_permissions "$name" "$staging"
    log_info "git reset --hard ${want:0:12} ($name)"
    if ! sudo -u "www-$name" env HOME="$root" git -C "$staging" reset --hard "$want" 2>&1 | tee -a "$LOG_DIR/$name.log" >&2; then
        rm -rf "$staging"
        die "git reset --hard failed for '$name' — live tree left unchanged"
    fi
    finalize_staging "$staging"
}

# Keep the live release plus up to RELEASES_KEEP-1 other newest (by
# directory name, which is timestamp-prefixed). Never deletes current.
prune_old_releases() {
    local name="$1"
    local keep="${RELEASES_KEEP:-5}"
    [[ "$keep" =~ ^[1-9][0-9]*$ ]] || keep=5
    local rels; rels="$(site_root "$name")/releases"
    [[ -d "$rels" ]] || return 0
    local current_real; current_real="$(current_release_real "$name")"

    local -a others=()
    local d
    for d in "$rels"/*/; do
        [[ -d "$d" ]] || continue
        d="${d%/}"
        [[ "$(basename "$d")" == .* ]] && continue
        if [[ -n "$current_real" && "$(readlink -f "$d")" == "$current_real" ]]; then
            continue
        fi
        others+=("$d")
    done
    (( ${#others[@]} == 0 )) && return 0

    local IFS=$'\n'
    local -a sorted
    mapfile -t sorted < <(printf '%s\n' "${others[@]}" | sort)
    local max_others=$((keep - 1))
    (( max_others < 0 )) && max_others=0
    local extras=$(( ${#sorted[@]} - max_others ))
    (( extras <= 0 )) && return 0

    local i
    for ((i = 0; i < extras; i++)); do
        log_info "pruning old release $(basename "${sorted[$i]}")"
        rm -rf "${sorted[$i]}"
    done
}
