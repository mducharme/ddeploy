#!/usr/bin/env bash
# One-command bootstrap for a fresh clone: configure (if needed) + init.
# Equivalent to running `./provision.sh configure` and
# `sudo ./provision.sh init` yourself — this just chains them for a new
# server. Safe to re-run: configure only runs if provisioner.conf doesn't
# exist yet, and init is already idempotent.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

conf=/etc/ddeploy/provisioner.conf
if ! sudo test -f "$conf"; then
    sudo ./provision.sh configure
else
    echo "$conf already exists — skipping configure (run 'sudo ./provision.sh configure' yourself to change settings)"
fi

echo
cf_path="$(sudo sed -nE 's/^CF_CREDENTIALS="([^"]*)".*/\1/p' "$conf" | head -1)"
key_path="$(sudo sed -nE 's/^GIT_DEPLOY_KEY="([^"]*)".*/\1/p' "$conf" | head -1)"
missing=0
if [[ -n "$cf_path" && ! -f "$cf_path" ]]; then
    echo "Missing: $cf_path (Cloudflare API token — place it there, chmod 600, before continuing)"
    missing=1
fi
if [[ -n "$key_path" && ! -f "$key_path" ]]; then
    echo "Missing: $key_path (shared git deploy key — place it there, chmod 600, before continuing)"
    missing=1
fi
if [[ "$missing" -eq 1 ]]; then
    echo
    echo "Place the file(s) above, then re-run ./install.sh (or just 'sudo ./provision.sh init')."
    exit 1
fi

echo "== sudo ./provision.sh init =="
sudo ./provision.sh init

echo
echo "Done. The ddeploy command is installed — next: ddeploy provision <name> <repo-url>"
