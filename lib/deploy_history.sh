#!/usr/bin/env bash
# Deploy history: a plain append-only log of every commit `deploy` (or a
# site's first deploy, from `provision`) has actually put live — what
# `deploy --rollback` walks backward through. Previews aren't covered —
# they're meant to be disposable, not something you'd roll a deploy back
# on; provision-preview/deploy-preview never call record_deploy.
#
# This is deliberately NOT a release-directory/symlink model (Capistrano/
# Deployer's approach) — the site's checkout is still a single in-place
# git working tree, same as a normal deploy. A rollback is a
# `git reset --hard` to an earlier commit already in that tree's own
# history (every site is cloned in full, no --depth), then the same hook
# replay a normal deploy runs. That means a rollback moves the CODE back;
# it does NOT undo any database migration a forward deploy already
# applied — there's no down-migration tracking here. See README.

deploy_history_path() { echo "$GENERATED_DIR/$1.deploys"; }

# Appends $2 (a full SHA) as the newest entry for site $1.
record_deploy() {
    local name="$1" sha="$2"
    mkdir -p "$GENERATED_DIR"
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sha" >> "$(deploy_history_path "$name")"
}

# Walks $1's history backward from the newest entry and prints the first
# SHA that isn't $2 (the current HEAD) — "what was live immediately
# before now," skipping past any run of entries that match current (a
# `deploy` that pulled nothing new still appends a duplicate rather than
# being skipped, to keep record_deploy a plain unconditional append).
# Returns 1 with no output if there's no earlier, different SHA on
# record — e.g. right after a fresh provision, before any real deploy.
previous_deploy_sha() {
    local name="$1" current="$2"
    local f; f="$(deploy_history_path "$name")"
    [[ -f "$f" ]] || return 1
    local -a lines
    mapfile -t lines < "$f"
    local i sha
    for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
        sha="${lines[$i]#*$'\t'}"
        if [[ -n "$sha" && "$sha" != "$current" ]]; then
            printf '%s' "$sha"
            return 0
        fi
    done
    return 1
}
