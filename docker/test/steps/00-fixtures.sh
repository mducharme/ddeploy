#!/usr/bin/env bash
# Runs INSIDE the web container, before `init`. Sets up a real local sshd
# + bare git repo + machine-user deploy keypair, so provision/deploy/
# provision-preview exercise the actual GIT_DEPLOY_KEY/sync_site_ssh path
# (lib/git_access.sh) against a real SSH server, not a file:// shortcut.
# This is test scaffolding, not something `init`/`provision` do themselves
# — a real deployment points GIT_DEPLOY_KEY at a real GitHub/GitLab/
# Bitbucket machine-user key instead.
set -euo pipefail
cd /opt/ddeploy
source docker/test/lib.sh

step "fixtures: local sshd + bare git repo"

mkdir -p /etc/ddeploy
ssh-keygen -A >/dev/null 2>&1 || true
systemctl enable --now ssh
pass "sshd running"

id -u deploy >/dev/null 2>&1 || useradd --system --create-home --shell /usr/sbin/nologin deploy
pass "'deploy' service user present (owns SITES_ROOT)"

if [[ ! -f /etc/ddeploy/git_deploy_key ]]; then
    ssh-keygen -t ed25519 -N '' -C 'ddeploy-test' -f /etc/ddeploy/git_deploy_key >/dev/null
fi
pass "deploy keypair present"

id -u gitfixture >/dev/null 2>&1 || useradd --create-home --shell /bin/bash gitfixture
mkdir -p /home/gitfixture/.ssh
cp /etc/ddeploy/git_deploy_key.pub /home/gitfixture/.ssh/authorized_keys
chown -R gitfixture:gitfixture /home/gitfixture/.ssh
chmod 700 /home/gitfixture/.ssh
chmod 600 /home/gitfixture/.ssh/authorized_keys
pass "gitfixture user + authorized_keys"

# Fixture-only convenience: seed 127.0.0.1's host key so the SSH clones
# below don't hang on an interactive host-key prompt. `init`'s own
# ssh-keyscan (github.com/gitlab.com/bitbucket.org) is verified separately
# in 02-init.sh — this is purely to make the local fixture repo reachable.
touch /etc/ssh/ssh_known_hosts
ssh-keyscan -t ed25519 127.0.0.1 >> /etc/ssh/ssh_known_hosts 2>/dev/null
sort -u -o /etc/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts
pass "known_hosts seeded for 127.0.0.1"

REPO=/srv/git/testsite.git
if [[ ! -d "$REPO" ]]; then
    mkdir -p "$REPO"
    git init --bare --initial-branch=main "$REPO" >/dev/null
fi

WORK="$(mktemp -d)"
cp -r docker/fixtures/testsite/. "$WORK/"
git -C "$WORK" init --initial-branch=main -q
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
git -C "$WORK" add -A
git -C "$WORK" commit -q -m 'v1'
git -C "$WORK" push -q "$REPO" main:main

# A second branch, for the branch-preview lifecycle test — distinct
# content so a curl to the preview can be told apart from the parent.
git -C "$WORK" checkout -q -b feature-a
sed -i 's/MARKER=v1/MARKER=preview-v1/' "$WORK/web/index.php"
git -C "$WORK" commit -q -am 'preview marker'
git -C "$WORK" push -q "$REPO" feature-a:feature-a
rm -rf "$WORK"

chown -R gitfixture:gitfixture "$REPO"

# Test-harness-only wrinkle: 03-lifecycle.sh pushes follow-up commits
# straight to this bare repo (as root, via a local path, to simulate "a
# new commit landed upstream") for the deploy/deploy-preview checks —
# git's ownership-mismatch safety check would otherwise refuse that once
# the repo's owned by gitfixture, not root. Not something a real
# deployment needs (it never touches the remote's bare repo directly).
git config --global --add safe.directory "$REPO"

pass "bare repo populated (main + feature-a)"

echo "ALL FIXTURE SETUP PASSED" | tee -a "$STEP_LOG"
