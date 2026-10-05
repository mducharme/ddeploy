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

# site_root is the site user's HOME (composer cache) but must not
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
# Every release (and preview checkout) gets core.fileMode=false: ddeploy
# owns the permissions of the tree (apply_permissions sets 640/2750), so
# a file committed as executable would otherwise show as locally
# modified in every release — and block any later checkout or pull that
# touches it ("Your local changes ... would be overwritten").
git_release_config() {
    git -c safe.directory='*' -C "$1" config core.fileMode false
}

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
    local out; out="$(mktemp)"
    if ! run_captured "$out" env GIT_SSH_COMMAND="$(git_ssh_command)" git clone "${branch_args[@]}" "$repo_url" "$staging"; then
        site_log "$name" "provision: git clone of $repo_url FAILED" error
        site_log_output "$name" "$out" 10
        rm -f "$out"
        die "git clone failed for '$name' — check the URL, and that the server's git key can read that repo (README \"Git access\")"
    fi
    rm -f "$out"
    git_trust_repo "$staging"
    git_release_config "$staging"
    finalize_staging "$staging"
}

# Next forward deploy: clone the live tree (local, fast), restore origin
# to the real remote (git clone of a path would otherwise set origin to
# that path), then fast-forward to origin's tip. Prints the new release
# path. Leaves current untouched; caller switches after hooks succeed.
# $2=1 (`deploy --force`) or ALLOW_FORCE_PUSH=true: a branch whose
# history was rewritten (force-push, rebase) is reset to origin's tip
# instead of failing. The live release keeps the old commit, so
# --rollback can still go back to it.
prepare_forward_release() {
    local name="$1" force="${2:-0}"
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
    git_release_config "$staging"
    # No apply_permissions here: the git work below runs on the clone as
    # git left it, and the caller (cmd_deploy) applies permissions to the
    # finished release afterwards. Doing it first would make git see
    # every committed-as-executable file as modified (755 -> 640).

    # deploy_branch (README "Default branch") is operator state, not
    # anything read from the repo — available immediately, no pull
    # needed to see it. Checked before pulling: if we're about to switch
    # away from the currently-tracked branch anyway, there's no reason to
    # pull --ff-only it first (and every reason not to — that pull could
    # itself fail non-fast-forward on a branch we're abandoning regardless).
    local target_branch; target_branch="$(read_deploy_branch "$name")"
    local current_branch; current_branch="$(git -C "$staging" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

    # Root + GIT_SSH_COMMAND, not sudo -u "www-$name": this is ddeploy's
    # own git operation, not project code, and provision/deploy already
    # require root end to end — routing it through the site's own user
    # bought no real isolation (root was still the one invoking sudo) and
    # was the whole reason a copy of the shared key used to live in every
    # site's own $HOME (see lib/git_access.sh, README "Git access").
    # safe.directory=* is scoped to this one invocation, for the same
    # reason as the clone above.
    # Git's output goes to the site log only when it fails (git_failed);
    # a routine fetch/pull isn't worth a line there.
    local out; out="$(mktemp)"
    if [[ -n "$target_branch" && "$target_branch" != "$current_branch" ]]; then
        log_info "'$name': switching to configured deploy_branch '$target_branch' (was '$current_branch')"
        run_captured "$out" env GIT_SSH_COMMAND="$(git_ssh_command)" git -c safe.directory='*' -C "$staging" fetch --quiet origin "$target_branch" \
            || git_failed "$name" "$out" "$staging" "failed to fetch deploy_branch '$target_branch' from origin — check the branch exists"
        run_captured "$out" git -c safe.directory='*' -C "$staging" checkout -B "$target_branch" "origin/$target_branch" \
            || git_failed "$name" "$out" "$staging" "failed to switch to deploy_branch '$target_branch'"
    else
        # Fetch, then decide — not `pull --ff-only`, which can't tell a
        # rewritten branch apart from any other failure.
        [[ -n "$current_branch" && "$current_branch" != "HEAD" ]] \
            || git_failed "$name" "$out" "$staging" "the live release isn't on a branch (detached HEAD) — pin one with 'provision $name --branch <branch>'"
        run_captured "$out" env GIT_SSH_COMMAND="$(git_ssh_command)" git -c safe.directory='*' -C "$staging" fetch --quiet origin "$current_branch" \
            || git_failed "$name" "$out" "$staging" "failed to fetch origin/$current_branch — live tree left unchanged"
        local head tip
        head="$(git -c safe.directory='*' -C "$staging" rev-parse HEAD)"
        tip="$(git -c safe.directory='*' -C "$staging" rev-parse FETCH_HEAD)"
        if git -c safe.directory='*' -C "$staging" merge-base --is-ancestor "$head" "$tip"; then
            log_info "git fast-forward to ${tip:0:7} ($name)"
            run_captured "$out" git -c safe.directory='*' -C "$staging" merge --ff-only --quiet "$tip" \
                || git_failed "$name" "$out" "$staging" "fast-forward to ${tip:0:7} failed — live tree left unchanged"
        else
            local rewritten="origin/$current_branch was force-pushed (live ${head:0:7} is no longer on it, tip is now ${tip:0:7})"
            local why=""
            if [[ "$force" == "1" ]]; then why="--force"
            elif [[ "$ALLOW_FORCE_PUSH" == "true" ]]; then why="ALLOW_FORCE_PUSH"
            fi
            [[ -n "$why" ]] \
                || git_failed "$name" "$out" "$staging" "$rewritten — live tree left unchanged; 'ddeploy deploy $name --force' deploys the new tip (or set ALLOW_FORCE_PUSH=true in provisioner.conf to always follow force-pushes)"
            log_warn "'$name': $rewritten — resetting to it ($why); 'deploy $name --rollback' goes back"
            site_log "$name" "deploy: $rewritten — reset to it ($why)" warn
            run_captured "$out" git -c safe.directory='*' -C "$staging" reset --hard --quiet "$tip" \
                || git_failed "$name" "$out" "$staging" "git reset --hard to ${tip:0:7} failed — live tree left unchanged"
        fi
    fi
    rm -f "$out"
    finalize_staging "$staging"
}

# A failed git step of a deploy: discards the staging release ($3, may be
# empty), puts git's own output in the site log, and dies with $4.
git_failed() {
    local name="$1" out="$2" staging="$3" msg="$4"
    [[ -n "$staging" ]] && rm -rf "$staging"
    site_log "$name" "deploy: git FAILED — $msg" error
    site_log_output "$name" "$out" 10
    rm -f "$out"
    die "'$name': $msg"
}

# `deploy --if-changed` / `deploy-preview --if-changed` (what the webhook
# worker runs): true when $2 (a checkout) is already at what origin's
# $3 branch points to, so there's nothing to build. Several pushes to the
# same branch queued behind one slow build collapse into one deploy
# this way — the first one deploys the branch tip, the rest find it
# already live — and a forge redelivering the same push is a no-op.
# Any doubt (ls-remote failing, no branch) means "changed": deploy.
checkout_matches_remote() {
    local name="$1" dir="$2" branch="$3"
    [[ -n "$branch" && "$branch" != "HEAD" ]] || return 1
    local head remote
    head="$(git -c safe.directory='*' -C "$dir" rev-parse HEAD 2>/dev/null)" || return 1
    remote="$(GIT_SSH_COMMAND="$(git_ssh_command)" git -c safe.directory='*' -C "$dir" \
        ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)" || return 1
    [[ -n "$remote" && "$remote" == "$head" ]]
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
    git_release_config "$staging"
    log_info "git reset --hard ${want:0:12} ($name)"
    # Root, not sudo -u "www-$name" — purely local (no network, no key
    # needed), same reasoning as prepare_forward_release above. Like
    # there, permissions come after (cmd_deploy).
    local out; out="$(mktemp)"
    run_captured "$out" git -c safe.directory='*' -C "$staging" reset --hard "$want" \
        || git_failed "$name" "$out" "$staging" "git reset --hard to ${want:0:12} failed — live tree left unchanged"
    rm -f "$out"
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
