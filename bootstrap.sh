#!/usr/bin/env bash
# Fresh-server bootstrap — run this BEFORE ddeploy is cloned anywhere on
# the box. Creates the `deploy` user, installs the minimum packages
# needed to clone (everything else — nginx, PHP, MariaDB, certbot — is
# `provision.sh init`'s job, not this script's), and clones ddeploy
# itself. Copy this one file onto a fresh Ubuntu 24.04 droplet and run
# it once, as root. Not meant to be curl-piped: the repo is presumably
# private, and the very next step (`./install.sh`, which runs
# `provision.sh configure`) needs a real interactive terminal, not a
# pipe's stdin.
#
# usage: ./bootstrap.sh <repo-url> [target-dir]
#   repo-url    git URL for your ddeploy checkout (ssh:// or https://)
#   target-dir  where to clone it (default: /home/deploy/provisioner —
#               matches provisioner.example.conf's own path assumption)
#
# Deliberately does NOT touch SSH access for the new `deploy` user (no
# authorized_keys seeding) — that's credential handling specific to your
# org, not this script's business. `su - deploy` below works regardless,
# since it's a local session, not a new SSH connection.
set -euo pipefail

log()  { printf '\033[36m[bootstrap]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || die "run as root"

repo_url="${1:-}"
target_dir="${2:-/home/deploy/provisioner}"
[[ -n "$repo_url" ]] || die "usage: $0 <repo-url> [target-dir]"

if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
        log "warning: this is built and tested for Ubuntu 24.04 (found ${PRETTY_NAME:-unknown}) — continuing anyway"
    fi
fi

log "== packages =="
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git sudo openssh-client ca-certificates
log "git/sudo/openssh-client present (everything else — nginx, PHP, MariaDB, certbot — is 'provision.sh init', not this script)"

log "== deploy user =="
if id -u deploy >/dev/null 2>&1; then
    log "'deploy' user already exists"
else
    useradd --create-home --shell /bin/bash deploy
    log "created 'deploy' user"
fi
usermod -aG sudo deploy
log "'deploy' is in the sudo group"

log "== clone ddeploy =="
if [[ -d "$target_dir/.git" ]]; then
    log "$target_dir already looks cloned — leaving it alone"
else
    mkdir -p "$(dirname "$target_dir")"
    git clone "$repo_url" "$target_dir"
    log "cloned $repo_url -> $target_dir"
fi
chown -R deploy:deploy "$target_dir"

cat <<EOF

Done. Next, as the deploy user:

  su - deploy
  cd $target_dir
  ./install.sh

That runs 'provision.sh configure' (interactive — domain, paths, PHP
versions) and then 'sudo provision.sh init'.
EOF
