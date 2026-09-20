#!/usr/bin/env bash
# Shared machine-user SSH key for git access to every client repo (a
# GitHub/GitLab/Bitbucket bot account with read access, NOT a native
# GitHub "deploy key" — those are hard-limited to one repo each and
# can't be reused across a fleet).
#
# The initial `git clone` in `provision` runs as root/whoever invoked
# the command, so it uses the key directly via GIT_SSH_COMMAND. Every
# `git pull` after that, in `deploy`, runs as the site's own www-<name>
# user, which has no populated $HOME/.ssh of its own, so the key + host
# keys are copied into $dir/.ssh (already that user's $HOME — for an
# atomic site that's the wrapper at $SITES_ROOT/<name>, not a release)
# so it can authenticate on its own.

GIT_KNOWN_HOSTS_SEED="github.com gitlab.com bitbucket.org"

require_git_deploy_key() {
    [[ -f "$GIT_DEPLOY_KEY" ]] || die "GIT_DEPLOY_KEY not found at $GIT_DEPLOY_KEY — place the shared machine-user private key there (chmod 600) before provisioning (see README)"
}

# For root-context git operations (the initial clone): use the key
# directly via GIT_SSH_COMMAND, against the system-wide known_hosts that
# `init` seeds.
git_ssh_command() {
    require_git_deploy_key
    echo "ssh -i $GIT_DEPLOY_KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o StrictHostKeyChecking=accept-new"
}

# Copies the shared key (under a fixed filename, not assuming a key
# type) plus known_hosts and a matching ssh config into $dir/.ssh, owned
# by www-<name>. Idempotent, and safe to call on every deploy — a
# rotated key on the server propagates on the next call, and re-running
# ssh-keyscan is cheap. Must run AFTER apply_permissions has set base
# ownership/perms on $dir, since it applies its own (stricter, 600/700)
# perms on top — a later whole-tree chmod would clobber them.
sync_site_ssh() {
    local name="$1" dir="$2"
    require_git_deploy_key
    local ssh_dir="$dir/.ssh"
    mkdir -p "$ssh_dir"
    cp "$GIT_DEPLOY_KEY" "$ssh_dir/deploy_key"
    # shellcheck disable=SC2086 # GIT_KNOWN_HOSTS_SEED is an intentional word list
    ssh-keyscan -t ed25519,rsa $GIT_KNOWN_HOSTS_SEED > "$ssh_dir/known_hosts" 2>/dev/null
    cat > "$ssh_dir/config" <<EOF
Host *
    IdentityFile $ssh_dir/deploy_key
    IdentitiesOnly yes
    UserKnownHostsFile $ssh_dir/known_hosts
    StrictHostKeyChecking accept-new
EOF
    chown -R "www-$name:www-data" "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "$ssh_dir/deploy_key" "$ssh_dir/known_hosts" "$ssh_dir/config"
}
