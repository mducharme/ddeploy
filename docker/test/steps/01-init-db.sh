#!/usr/bin/env bash
# Runs INSIDE the dbhost container. provisioner.conf (DB_ADMIN_CREDENTIALS,
# DB_ALLOWED_HOSTS) was written by test/run.sh before this runs.
set -euo pipefail
cd /opt/ddeploy
source docker/test/lib.sh

step "init-db"
./provision.sh init-db

step "init-db: checks"
assert_cmd_ok "mariadb is active" systemctl is-active --quiet mariadb
assert_file_exists "$(grep -oP '(?<=^DB_ADMIN_CREDENTIALS=").*(?=")' provisioner.conf)" "admin credentials file written"

step "init-db: idempotent re-run reuses credentials"
admin_cnf="$(grep -oP '(?<=^DB_ADMIN_CREDENTIALS=").*(?=")' provisioner.conf)"
before="$(md5sum "$admin_cnf" | cut -d' ' -f1)"
./provision.sh init-db
after="$(md5sum "$admin_cnf" | cut -d' ' -f1)"
[[ "$before" == "$after" ]] && pass "admin credentials unchanged on re-run" || fail "admin credentials regenerated on re-run"

echo "ALL DBHOST CHECKS PASSED" | tee -a "$STEP_LOG"
