#!/usr/bin/env bash
# Runs INSIDE the web container, after 00-fixtures.sh and 02-init.sh. The
# full site lifecycle against real infrastructure: provision, deploy,
# branch preview (shared mode), backup/restore against real object
# storage, prune-previews (exercising the real git-ls-remote-exit-code
# path), and removal.
set -euo pipefail
cd /opt/ddeploy
source docker/test/lib.sh
source lib/common.sh
source lib/db.sh
source lib/backup.sh
load_conf

REPO_URL="ssh://gitfixture@127.0.0.1/srv/git/testsite.git"
BARE=/srv/git/testsite.git
AUTH_PASS="$(cat /etc/ddeploy/basic-auth-password 2>/dev/null || true)"

# --- provision -------------------------------------------------------

step "provision testsite"
./provision.sh provision testsite "$REPO_URL"
sleep 1  # nginx's graceful reload briefly straddles old/new config; give it a beat before curling

step "provision: checks"
assert_cmd_ok "www-testsite Linux user created" id -u www-testsite
assert_file_exists "/etc/nginx/sites-enabled/testsite.conf" "vhost enabled"
assert_file_exists "/etc/php/8.3/fpm/pool.d/testsite.conf" "FPM pool installed"
assert_file_exists "$SITES_ROOT/testsite/.env" "laravel-scheme .env written"
assert_cmd_ok "nginx config valid" nginx -t

out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "MARKER=v1" "main vhost serves v1"
assert_contains "$out" "DB_OK" "app can connect to its own DB with the credentials db_ensure wrote"

out_alt="$(curl_site alt-testsite.staging.ddeploy.test)"
assert_contains "$out_alt" "MARKER=v1" "additional_hostnames vhost reaches the same site"

assert_file_exists "/etc/letsencrypt/live/custom.ddeploy.test/fullchain.pem" "custom-domain cert issued (two-phase HTTP-01 mock)"
out_custom="$(curl_site custom.ddeploy.test)"
assert_contains "$out_custom" "MARKER=v1" "custom-domain vhost reaches the same site"

list_out="$(./provision.sh list)"
assert_contains "$list_out" "testsite" "list shows testsite"

# --- probe row for backup/restore-database verification ---------------

mysql --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" testsite \
    -e "CREATE TABLE probe (id INT); INSERT INTO probe VALUES (1);"
pass "seeded a probe row directly in the real database (for the restore check below)"

# --- deploy ------------------------------------------------------------

step "deploy testsite (git pull --ff-only)"
WORK="$(mktemp -d)"
git clone -q "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
sed -i 's/MARKER=v1/MARKER=v2/' "$WORK/web/index.php"
git -C "$WORK" commit -q -am 'v2'
git -C "$WORK" push -q origin main
rm -rf "$WORK"

./provision.sh deploy testsite
sleep 1

out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "MARKER=v2" "deploy pulled the new commit (git_deploy_key + sync_site_ssh work end to end)"

# --- branch preview (shared mode, the default) -------------------------

step "provision-preview testsite feature-a"
./provision.sh provision-preview testsite feature-a
sleep 1  # same nginx-reload settling reason as above

PREVIEW=testsite-feature-a
assert_cmd_fails "shared-mode preview has NO Linux user of its own" id -u "www-$PREVIEW"
assert_file_exists "/etc/nginx/sites-enabled/$PREVIEW.conf" "preview vhost enabled"

assert_cmd_fails "preview requires auth (no credentials -> non-2xx)" curl -fsSk --resolve "$PREVIEW.staging.ddeploy.test:443:127.0.0.1" "https://$PREVIEW.staging.ddeploy.test/"
if [[ -n "$AUTH_PASS" ]]; then
    out="$(curl -fsSk -u "preview:$AUTH_PASS" --resolve "$PREVIEW.staging.ddeploy.test:443:127.0.0.1" "https://$PREVIEW.staging.ddeploy.test/")"
    assert_contains "$out" "MARKER=preview-v1" "preview serves the feature-a branch"
    assert_contains "$out" "DB_OK" "preview's DB link (shared mode) actually works, not just resolves"
else
    fail "never captured the generated basic-auth password from init's output"
fi

list_out="$(./provision.sh list)"
assert_contains "$list_out" "testsite/feature-a (shared)" "list shows the preview, shared mode, resolved to its parent"

step "deploy-preview testsite feature-a"
WORK="$(mktemp -d)"
git clone -q --branch feature-a "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
sed -i 's/MARKER=preview-v1/MARKER=preview-v2/' "$WORK/web/index.php"
git -C "$WORK" commit -q -am 'preview v2'
git -C "$WORK" push -q origin feature-a
rm -rf "$WORK"

./provision.sh deploy-preview testsite feature-a
sleep 1
out="$(curl -fsSk -u "preview:$AUTH_PASS" --resolve "$PREVIEW.staging.ddeploy.test:443:127.0.0.1" "https://$PREVIEW.staging.ddeploy.test/")"
assert_contains "$out" "MARKER=preview-v2" "deploy-preview fetch+reset picked up the new commit"

# --- backup / restore, against real object storage (MinIO) -------------

step "backup-uploads / backup-database (all sites)"
echo "hello from uploads" > "$SITES_ROOT/testsite/private-uploads/marker.txt"

backup_out="$(./provision.sh backup-uploads 2>&1)"
assert_contains "$backup_out" "skipping 'testsite-feature-a'" "backup-uploads skips the shared-mode preview"
assert_not_contains "$backup_out" "backup-uploads failed" "backup-uploads succeeded for testsite"

db_backup_out="$(./provision.sh backup-database 2>&1)"
assert_contains "$db_backup_out" "skipping 'testsite-feature-a'" "backup-database skips the shared-mode preview"
assert_not_contains "$db_backup_out" "backup-database failed" "backup-database succeeded for testsite"

remote="$(backup_remote_spec)"
uploads_listing="$(rclone lsf "${remote}/testsite/private-uploads/" 2>/dev/null || true)"
assert_contains "$uploads_listing" "marker.txt" "uploaded marker.txt is actually in object storage"
db_listing="$(rclone lsf "${remote}/testsite/db/" 2>/dev/null || true)"
[[ -n "$db_listing" ]] && pass "a database dump landed in object storage" || fail "no database dump found in object storage"

step "restore-uploads / restore-database"
rm -f "$SITES_ROOT/testsite/private-uploads/marker.txt"
mysql --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" testsite -e "DROP TABLE probe;"

./provision.sh restore-uploads testsite --yes
assert_file_exists "$SITES_ROOT/testsite/private-uploads/marker.txt" "restore-uploads brought the file back"

./provision.sh restore-database testsite --yes
probe_count="$(mysql --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" -N -B testsite -e "SELECT COUNT(*) FROM probe;")"
[[ "$probe_count" == "1" ]] && pass "restore-database brought the probe row back" || fail "probe table missing/empty after restore (got: $probe_count)"

# --- prune-previews: real git-ls-remote-exit-code path ------------------

step "prune-previews (feature-a branch deleted upstream)"
git -C "$BARE" branch -D feature-a >/dev/null
./provision.sh prune-previews
assert_file_absent "/etc/nginx/sites-enabled/$PREVIEW.conf" "prune-previews removed the preview whose branch is gone"

# --- remove --------------------------------------------------------------

step "remove testsite --purge-db --purge-files"
./provision.sh remove testsite --purge-db --purge-files

assert_file_absent "/etc/nginx/sites-enabled/testsite.conf" "vhost removed"
assert_file_absent "/etc/php/8.3/fpm/pool.d/testsite.conf" "FPM pool removed"
assert_cmd_fails "www-testsite Linux user removed" id -u www-testsite
assert_file_absent "$SITES_ROOT/testsite" "site directory removed"
db_exists="$(mysql --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" -N -B -e "SHOW DATABASES LIKE 'testsite';")"
[[ -z "$db_exists" ]] && pass "database dropped" || fail "database 'testsite' still exists after --purge-db"
assert_cmd_ok "nginx config still valid after removal" nginx -t

echo "ALL LIFECYCLE CHECKS PASSED" | tee -a "$STEP_LOG"
