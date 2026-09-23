#!/usr/bin/env bash
# Shared machine-user SSH key for git access to every client repo (a
# GitHub/GitLab/Bitbucket bot account with read access, NOT a native
# GitHub "deploy key" — those are hard-limited to one repo each and
# can't be reused across a fleet).
#
# ddeploy's OWN git operations (clone/fetch/pull/checkout/reset — see
# lib/releases.sh, cmd_preview.sh) always run as root, straight off
# GIT_DEPLOY_KEY via GIT_SSH_COMMAND. They never need the key to exist
# anywhere but that one root-owned file.
#
# The one thing that DOES need live key access from inside the site's
# own, less-trusted www-<name> user is opaque, project-declared code —
# `composer install` against a private VCS package, a hooks.post-start
# `exec` step, `.provisioner/post-*.sh` — since ddeploy can't know in
# advance whether any of that needs git/SSH. start_deploy_ssh_agent /
# stop_deploy_ssh_agent bracket just that hook-replay window with a
# per-deploy ssh-agent: root loads the key into an agent that runs AS
# that user, so the key material crosses into it over the local agent
# socket but is never written to a file that user (or a future
# compromise of its web-facing code) can read. Older ddeploy versions
# instead copied the key straight into every site's own $HOME/.ssh — a
# standing, always-readable copy of a fleet-wide secret; see README
# "Git access" and lib/cmd_provision.sh/cmd_deploy.sh's cleanup of that.

GIT_KNOWN_HOSTS_SEED="github.com gitlab.com bitbucket.org"

require_git_deploy_key() {
    [[ -f "$GIT_DEPLOY_KEY" ]] || die "GIT_DEPLOY_KEY not found at $GIT_DEPLOY_KEY — place the shared machine-user private key there (chmod 600) before provisioning (see README)"
}

# For root-context git operations (clone/fetch/pull/checkout/reset, all
# of them — see lib/releases.sh, lib/cmd_preview.sh): use the key
# directly via GIT_SSH_COMMAND, against the system-wide known_hosts that
# `init` seeds.
git_ssh_command() {
    require_git_deploy_key
    echo "ssh -i $GIT_DEPLOY_KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o StrictHostKeyChecking=accept-new"
}

# Starts an ssh-agent AS $1 (so its socket is reachable only by that
# user and by root — nothing else), loads GIT_DEPLOY_KEY into it (root
# reads the key file directly; ssh-add hands the key to the agent over
# its socket, never through a file $1 can read), and sets
# DEPLOY_SSH_AUTH_SOCK/DEPLOY_SSH_AGENT_PID for the caller and for
# lib/hooks.sh / lib/custom_hooks.sh to thread into every sudo -u
# subprocess for the rest of this one deploy.
#
# Non-fatal on failure: most sites never touch git/SSH from inside a
# hook at all, and a broken/missing key here must not block a deploy
# that was never going to need it — a site that DOES need it then fails
# loudly and specifically at that one composer/exec step, same as if the
# key were simply missing.
#
# Caller MUST pair a successful start with stop_deploy_ssh_agent — via a
# trap, so it still happens if a hook fails — the agent, and the key
# material inside it, must not outlive the one provision/deploy call
# that started it.
start_deploy_ssh_agent() {
    local exec_user="$1"
    DEPLOY_SSH_AUTH_SOCK=""
    DEPLOY_SSH_AGENT_PID=""
    if [[ ! -f "$GIT_DEPLOY_KEY" ]]; then
        log_warn "GIT_DEPLOY_KEY not found at $GIT_DEPLOY_KEY — any hook step needing git/SSH (e.g. a private composer package) will fail"
        return 0
    fi

    local out
    if ! out="$(sudo -u "$exec_user" ssh-agent -s 2>/dev/null)"; then
        log_warn "failed to start an ssh-agent for $exec_user — any hook step needing git/SSH will fail"
        return 0
    fi
    local sock pid
    sock="$(sed -n 's/^SSH_AUTH_SOCK=\([^;]*\);.*/\1/p' <<< "$out")"
    pid="$(sed -n 's/^SSH_AGENT_PID=\([^;]*\);.*/\1/p' <<< "$out")"
    if [[ -z "$sock" || -z "$pid" ]]; then
        log_warn "couldn't parse ssh-agent output for $exec_user — any hook step needing git/SSH will fail"
        return 0
    fi
    if ! SSH_AUTH_SOCK="$sock" ssh-add "$GIT_DEPLOY_KEY" >/dev/null 2>&1; then
        log_warn "failed to load GIT_DEPLOY_KEY into the ssh-agent for $exec_user — any hook step needing git/SSH will fail"
        kill "$pid" 2>/dev/null || true
        return 0
    fi
    DEPLOY_SSH_AUTH_SOCK="$sock"
    DEPLOY_SSH_AGENT_PID="$pid"
}

# Kills the agent started by start_deploy_ssh_agent, if any. Safe to
# call unconditionally (e.g. from a trap) even when start failed, was
# never called, or was already stopped.
stop_deploy_ssh_agent() {
    [[ -n "${DEPLOY_SSH_AGENT_PID:-}" ]] && kill "$DEPLOY_SSH_AGENT_PID" 2>/dev/null
    DEPLOY_SSH_AUTH_SOCK=""
    DEPLOY_SSH_AGENT_PID=""
}
