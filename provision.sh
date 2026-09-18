#!/usr/bin/env bash
# Staging provisioner CLI. See README.md. Every per-server value lives
# in provisioner.conf, never here — this script is identical across servers.
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
# shellcheck source=lib/custom_domain.sh
source "$LIB_DIR/custom_domain.sh"
# shellcheck source=lib/backup.sh
source "$LIB_DIR/backup.sh"
# shellcheck source=lib/db_backup.sh
source "$LIB_DIR/db_backup.sh"
# shellcheck source=lib/cmd_init.sh
source "$LIB_DIR/cmd_init.sh"
# shellcheck source=lib/cmd_init_db.sh
source "$LIB_DIR/cmd_init_db.sh"
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
# shellcheck source=lib/cmd_backup.sh
source "$LIB_DIR/cmd_backup.sh"
# shellcheck source=lib/cmd_db_backup.sh
source "$LIB_DIR/cmd_db_backup.sh"

usage() {
    cat <<'EOF'
usage: provision.sh <command> [args]

commands:
  init                          set up a web server (packages, PHP, TLS, firewall)
  init-db                       set up a dedicated database server
  provision <name> [repo-url]   stand up a site (see: provision.sh provision -h)
  deploy <name>                 pull + replay deploy hooks + reload
  remove <name> [opts]          disable a site (see: provision.sh remove -h)
  list                          table of provisioned sites
  provision-all                 provision every site in ./manifest
  deploy-all                    deploy every provisioned site
  backup-uploads [name]         sync upload_dirs to object storage (needs BACKUP_ENABLED=true)
  backup-database [name]        dump + upload each site's DB (needs DB_BACKUP_ENABLED=true)
EOF
}

main() {
    local cmd="${1:-}"; [[ $# -gt 0 ]] && shift || true
    case "$cmd" in
        init)           cmd_init "$@" ;;
        init-db)        cmd_init_db "$@" ;;
        provision)      cmd_provision "$@" ;;
        deploy)         cmd_deploy "$@" ;;
        remove)         cmd_remove "$@" ;;
        list)           cmd_list "$@" ;;
        provision-all)  cmd_provision_all "$@" ;;
        deploy-all)     cmd_deploy_all "$@" ;;
        backup-uploads) cmd_backup_uploads "$@" ;;
        backup-database) cmd_backup_database "$@" ;;
        -h|--help|help|"") usage ;;
        *) usage; die "unknown command: $cmd" ;;
    esac
}

main "$@"
