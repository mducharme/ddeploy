#!/usr/bin/env bash
# Staging provisioner CLI. See README.md for the full build spec this
# implements. Fleet-ready: every per-droplet value lives in
# provisioner.conf, never here — this script is identical across droplets.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=lib/hooks.sh
source "$LIB_DIR/hooks.sh"
# shellcheck source=lib/custom_hooks.sh
source "$LIB_DIR/custom_hooks.sh"
# shellcheck source=lib/cms.sh
source "$LIB_DIR/cms.sh"
# shellcheck source=lib/git_access.sh
source "$LIB_DIR/git_access.sh"
# shellcheck source=lib/cloudflare.sh
source "$LIB_DIR/cloudflare.sh"
# shellcheck source=lib/php.sh
source "$LIB_DIR/php.sh"
# shellcheck source=lib/db.sh
source "$LIB_DIR/db.sh"
# shellcheck source=lib/vhost.sh
source "$LIB_DIR/vhost.sh"
# shellcheck source=lib/cmd_init.sh
source "$LIB_DIR/cmd_init.sh"
# shellcheck source=lib/cmd_provision.sh
source "$LIB_DIR/cmd_provision.sh"
# shellcheck source=lib/cmd_deploy.sh
source "$LIB_DIR/cmd_deploy.sh"
# shellcheck source=lib/cmd_remove.sh
source "$LIB_DIR/cmd_remove.sh"
# shellcheck source=lib/cmd_list.sh
source "$LIB_DIR/cmd_list.sh"
# shellcheck source=lib/cmd_fleet.sh
source "$LIB_DIR/cmd_fleet.sh"

usage() {
    cat <<'EOF'
usage: provision.sh <command> [args]

commands:
  init                          make a bare droplet ready (packages, PHP, TLS)
  provision <name> [repo-url]   stand up a site (see: provision.sh provision -h)
  deploy <name>                 pull + replay deploy hooks + reload
  remove <name> [opts]          disable a site (see: provision.sh remove -h)
  list                          table of provisioned sites
  provision-all                 provision every site in ./manifest
  deploy-all                    deploy every provisioned site
EOF
}

main() {
    local cmd="${1:-}"; [[ $# -gt 0 ]] && shift || true
    case "$cmd" in
        init)           cmd_init "$@" ;;
        provision)      cmd_provision "$@" ;;
        deploy)         cmd_deploy "$@" ;;
        remove)         cmd_remove "$@" ;;
        list)           cmd_list "$@" ;;
        provision-all)  cmd_provision_all "$@" ;;
        deploy-all)     cmd_deploy_all "$@" ;;
        -h|--help|help|"") usage ;;
        *) usage; die "unknown command: $cmd" ;;
    esac
}

main "$@"
