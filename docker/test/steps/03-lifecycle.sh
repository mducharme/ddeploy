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
source lib/config.sh
source lib/db.sh
source lib/backup.sh
load_conf

REPO_URL="ssh://gitfixture@127.0.0.1/srv/git/testsite.git"
BARE=/srv/git/testsite.git
AUTH_PASS="$(cat /etc/ddeploy/basic-auth-password 2>/dev/null || true)"
HOOK_HOST="hooks.staging.ddeploy.test"
HOOK_CLONE="https://127.0.0.1/srv/git/testsite.git"

hmac_sha256_file() {
    python3 -c '
import hmac, hashlib, pathlib, sys
secret = pathlib.Path(sys.argv[1]).read_bytes().strip()
body = pathlib.Path(sys.argv[2]).read_bytes()
print("sha256=" + hmac.new(secret, body, hashlib.sha256).hexdigest())
' /etc/ddeploy/webhook.secret "$1"
}

# $1 path (/github or /bitbucket) $2 signature header name $3 event header name
# $4 event value $5 body file. Prints HTTP status code.
post_hook() {
    local path="$1" sig_hdr="$2" ev_hdr="$3" event="$4" body="$5"
    local sig
    sig="$(hmac_sha256_file "$body")"
    curl -sS -o /tmp/hook-body -w "%{http_code}" -k \
        --resolve "${HOOK_HOST}:443:127.0.0.1" \
        -X POST "https://${HOOK_HOST}${path}" \
        -H "Content-Type: application/json" \
        -H "${sig_hdr}: ${sig}" \
        -H "${ev_hdr}: ${event}" \
        --data-binary @"$body"
}

write_github_push() {
    local branch="$1" out="$2"
    python3 -c '
import json, sys
branch, clone = sys.argv[1], sys.argv[2]
print(json.dumps({
    "ref": "refs/heads/" + branch,
    "after": "0" * 40,
    "deleted": False,
    "repository": {
        "clone_url": clone,
        "ssh_url": "ssh://gitfixture@127.0.0.1/srv/git/testsite.git",
    },
}))
' "$branch" "$HOOK_CLONE" > "$out"
}

write_github_pr() {
    local action="$1" branch="$2" head_repo="$3" out="$4"
    python3 -c '
import json, sys
action, branch, head_repo, clone = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
print(json.dumps({
    "action": action,
    "pull_request": {
        "number": 42,
        "head": {"ref": branch, "sha": "0"*40, "repo": {"full_name": head_repo}},
        "base": {"repo": {"full_name": "gitfixture/testsite"}},
    },
    "repository": {
        "clone_url": clone,
        "ssh_url": "ssh://gitfixture@127.0.0.1/srv/git/testsite.git",
        "html_url": "https://github.com/gitfixture/testsite",
    },
}))
' "$action" "$branch" "$head_repo" "$HOOK_CLONE" > "$out"
}

# Drain the spool, then wait until the systemd path worker (if it also
# picked the job up) has finished. A second hook-worker against an empty
# queue is a no-op; returning before provision-preview finishes is what
# flakes the preview asserts.
flush_hooks() {
    local i=0
    ./provision.sh hook-worker
    while (( i < 60 )); do
        if ! compgen -G /var/lib/ddeploy/queue/new/job-*.json >/dev/null \
            && ! systemctl is-active --quiet ddeploy-hook-worker.service; then
            ./provision.sh hook-worker
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
        ./provision.sh hook-worker || true
    done
    fail "webhook queue did not drain"
}

write_bitbucket_pr() {
    local event="$1" branch="$2" src_uuid="$3" dst_uuid="$4" out="$5"
    python3 -c '
import json, sys
event, branch, src, dst, clone = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
print(json.dumps({
    "pullrequest": {
        "id": 7,
        "source": {
            "branch": {"name": branch},
            "commit": {"hash": "0"*40},
            "repository": {"uuid": src, "full_name": "gitfixture/testsite",
                           "links": {"clone": [{"name": "https", "href": clone}]}},
        },
        "destination": {
            "repository": {"uuid": dst, "full_name": "gitfixture/testsite",
                           "links": {"clone": [{"name": "https", "href": clone}]}},
        },
    },
    "repository": {
        "full_name": "gitfixture/testsite",
        "links": {"clone": [{"name": "https", "href": clone},
                            {"name": "ssh", "href": "ssh://gitfixture@127.0.0.1/srv/git/testsite.git"}]},
    },
}))
' "$event" "$branch" "$src_uuid" "$dst_uuid" "$HOOK_CLONE" > "$out"
}

# --- provision -------------------------------------------------------

step "provision testsite"
./provision.sh provision testsite "$REPO_URL"
sleep 1  # nginx's graceful reload briefly straddles old/new config; give it a beat before curling
LIVE="$(site_dir testsite)"

step "provision: checks"
assert_cmd_ok "www-testsite Linux user created" id -u www-testsite
assert_file_exists "/etc/nginx/sites-enabled/testsite.conf" "vhost enabled"
assert_file_exists "/etc/php/8.3/fpm/pool.d/testsite.conf" "FPM pool installed"
assert_cmd_ok "current is a symlink" test -L "$SITES_ROOT/testsite/current"
assert_cmd_ok "releases directory exists" test -d "$SITES_ROOT/testsite/releases"
assert_cmd_ok "nginx root goes through current" grep -q "/current/" /etc/nginx/sites-available/testsite.conf
assert_file_exists "$LIVE/.env" "laravel-scheme .env written"
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

step "logs and preview-url"
logs_out="$(./provision.sh logs testsite -n 20)"
assert_contains "$logs_out" "provision:" "logs shows the site's provision line"
assert_cmd_fails "logs rejects a name that would walk out of LOG_DIR" ./provision.sh logs '../etc/passwd'
assert_cmd_fails "logs errors on a name with no log file" ./provision.sh logs nosuchsite
purl="$(./provision.sh preview-url testsite feature-a)"
[[ "$purl" == "https://testsite-feature-a.staging.ddeploy.test" ]] \
    && pass "preview-url is deterministic (site need not exist yet)" \
    || fail "preview-url returned '$purl'"

step "scoped nginx extras (allowlisted knobs, not raw snippets)"
vhost="$(cat /etc/nginx/sites-available/testsite.conf)"
assert_contains "$vhost" 'add_header X-Content-Type-Options "nosniff" always;' "security_headers rendered into the vhost"
assert_contains "$vhost" "location ^~ /old-home { return 301 /; }" "redirects rendered as a prefix location"
assert_contains "$vhost" "expires 7d;" "static_cache rendered"
assert_contains "$vhost" "location ^~ /uploads/" "deny_php_in_uploads derived /uploads from the web-accessible upload_dirs entry"

hdrs="$(curl -sSk -D- -o /dev/null --resolve "testsite.staging.ddeploy.test:443:127.0.0.1" "https://testsite.staging.ddeploy.test/" | tr '[:upper:]' '[:lower:]')"
assert_contains "$hdrs" "x-content-type-options: nosniff" "security_headers actually sent"
redir="$(curl -sSk -o /dev/null -w '%{http_code}' --resolve "testsite.staging.ddeploy.test:443:127.0.0.1" "https://testsite.staging.ddeploy.test/old-home")"
[[ "$redir" == "301" ]] && pass "redirect /old-home is 301" || fail "redirect /old-home returned $redir, expected 301"
css_hdrs="$(curl -sSk -D- -o /dev/null --resolve "testsite.staging.ddeploy.test:443:127.0.0.1" "https://testsite.staging.ddeploy.test/style.css" | tr '[:upper:]' '[:lower:]')"
assert_contains "$css_hdrs" "cache-control:" "static_cache sets Cache-Control on css"
mkdir -p "$LIVE/web/uploads"
printf '<?php echo "PWN";\n' > "$LIVE/web/uploads/evil.php"
chown www-testsite:www-data "$LIVE/web/uploads/evil.php"
php_code="$(curl -sSk -o /dev/null -w '%{http_code}' --resolve "testsite.staging.ddeploy.test:443:127.0.0.1" "https://testsite.staging.ddeploy.test/uploads/evil.php")"
[[ "$php_code" == "403" ]] && pass "PHP under /uploads is denied" || fail "GET /uploads/evil.php returned $php_code, expected 403"

# static_cache and deny_php_in_uploads both render as a location for
# /uploads/ — a static asset there must still get cached, not be
# silently shadowed by the deny-php prefix location (nginx's ^~ match
# skips all top-level regex locations once it wins, including
# build_static_cache_block's own).
printf 'not a real png, just needs the extension\n' > "$LIVE/web/uploads/logo.png"
chown www-testsite:www-data "$LIVE/web/uploads/logo.png"
uploads_asset_hdrs="$(curl -sSk -D- -o /dev/null --resolve "testsite.staging.ddeploy.test:443:127.0.0.1" "https://testsite.staging.ddeploy.test/uploads/logo.png" | tr '[:upper:]' '[:lower:]')"
assert_contains "$uploads_asset_hdrs" "200" "static asset under the deny-php-protected /uploads/ still serves"
assert_contains "$uploads_asset_hdrs" "cache-control:" "static_cache still applies under a deny_php_in_uploads-protected prefix"

step "migrating an existing flat checkout to the releases layout stays reachable"
# Reverts testsite to look exactly like a site a pre-atomic-release
# ddeploy build left behind: no releases/current, a vhost with a
# literal (non-symlinked) root path baked in. Then runs `deploy` and
# polls throughout — this is the one-time migration
# ensure_releases_layout does on a site's first deploy/provision after
# upgrading to this code, and it must not leave the site 404ing until
# hook replay finishes (composer install, migrations, ... — potentially
# a long time). lib/releases.sh's migration branch is supposed to
# bridge that by re-rendering the vhost immediately, before hooks run,
# not leave it to the caller's own later install_vhost call.
FLAT_TARGET="$(readlink -f "$SITES_ROOT/testsite/current")"
rm -f "$SITES_ROOT/testsite/current"
shopt -s dotglob
for f in "$FLAT_TARGET"/*; do mv "$f" "$SITES_ROOT/testsite/"; done
shopt -u dotglob
rmdir "$FLAT_TARGET"
rm -rf "$SITES_ROOT/testsite/releases"
chown -R www-testsite:www-data "$SITES_ROOT/testsite"
find "$SITES_ROOT/testsite" -maxdepth 1 -type d -exec chmod 2750 {} \;
# Both vhosts (the main one and the custom-domain one) get this same
# literal-path treatment — a real pre-atomic-release site would have
# both, and the migration bridge is supposed to fix both.
sed -i "s#$SITES_ROOT/testsite/current/#$SITES_ROOT/testsite/#g" \
    /etc/nginx/sites-available/testsite.conf /etc/nginx/sites-available/testsite-custom.conf
nginx -t && systemctl reload nginx
sleep 1
assert_cmd_ok "sanity: flat-layout testsite still serves before migration" curl -fsSk --resolve "testsite.staging.ddeploy.test:443:127.0.0.1" "https://testsite.staging.ddeploy.test/"
assert_cmd_ok "sanity: flat-layout custom domain still serves before migration" curl -fsSk --resolve "custom.ddeploy.test:443:127.0.0.1" "https://custom.ddeploy.test/"

poll_loop() {
    local host="$1" out="$2"
    : > "$out"
    while true; do
        code="$(curl -sk -o /dev/null -w '%{http_code}' --resolve "${host}:443:127.0.0.1" "https://${host}/" 2>/dev/null || echo "000")"
        echo "$code" >> "$out"
    done
}
poll_loop testsite.staging.ddeploy.test /tmp/migration-poll-main.log &
POLL_MAIN_PID=$!
poll_loop custom.ddeploy.test /tmp/migration-poll-custom.log &
POLL_CUSTOM_PID=$!

./provision.sh deploy testsite

# `deploy` itself always ends with a handful of `systemctl reload nginx`
# calls (FPM pool, vhost, custom-domain vhost) whose async worker
# respawn doesn't necessarily finish the instant the command returns —
# every other deploy-then-curl check in this script already gives that
# a beat ("nginx's graceful reload briefly straddles old/new config").
# Keep polling through that same settling window here, so the tail
# check below measures actual post-deploy health, not a race against
# deploy's own ordinary last reload.
sleep 1
kill "$POLL_MAIN_PID" "$POLL_CUSTOM_PID" 2>/dev/null || true
wait "$POLL_MAIN_PID" "$POLL_CUSTOM_PID" 2>/dev/null || true

# A brief blip right as the migration starts (the instant the old
# checkout is moved out from under the old vhost path, before the
# bridging install_vhost's own nginx reload completes) is the best this
# can do without a fancier zero-downtime reload mechanism — that's fine.
# What must NOT happen is the old bug: failures spanning the entire
# deploy because nothing re-pointed the vhost until hook replay
# finished. Guard both: the bad fraction stays small (old bug: ~60%+
# for this fixture's ~1.5s deploy), and the tail (now well past deploy's
# own return, not raced against it) is clean.
for pair in "main:/tmp/migration-poll-main.log" "custom domain:/tmp/migration-poll-custom.log"; do
    label="${pair%%:*}" log="${pair#*:}"
    total="$(wc -l < "$log")"
    bad="$(grep -vc '^200$' "$log" || true)"
    half=$((total / 2))
    [[ "$bad" -lt "$half" ]] && pass "$label: migration outage stayed brief, not the whole deploy ($bad/$total polls bad)" || fail "$label: $bad/$total polls were non-200 — migration left the site down for most of the deploy, not just a brief reload blip"
    tail_bad="$(tail -n 15 "$log" | grep -vc '^200$' || true)"
    [[ "$tail_bad" -eq 0 ]] && pass "$label: site was back up well before the deploy finished" || fail "$label: still returning errors in the last few polls before deploy completed"
    rm -f "$log"
done

assert_cmd_ok "current is a symlink again after migration" test -L "$SITES_ROOT/testsite/current"
out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "MARKER=v1" "testsite still serves its real content after the migration"

step "persistent files: linked into the persistent store"
assert_cmd_ok "uploads dir is a symlink" test -L "$LIVE/private-uploads"
assert_contains "$(readlink "$LIVE/private-uploads")" "$PERSISTENT_ROOT/testsite/private-uploads" "uploads symlinked into PERSISTENT_ROOT"
assert_cmd_ok ".env is a symlink" test -L "$LIVE/.env"
assert_contains "$(readlink "$LIVE/.env")" "$PERSISTENT_ROOT/testsite/.env" ".env symlinked into PERSISTENT_ROOT"
assert_cmd_ok "persistent_files entry (shared-notes.txt) is a symlink" test -L "$LIVE/shared-notes.txt"
assert_contains "$(readlink "$LIVE/shared-notes.txt")" "$PERSISTENT_ROOT/testsite/shared-notes.txt" "persistent_files entry symlinked into PERSISTENT_ROOT"
echo "important client note" > "$LIVE/shared-notes.txt"

step "per-site config overrides (.ddeploy/config.yaml)"
assert_cmd_ok "vhost has the overridden client_max_body_size" grep -q "client_max_body_size 256m;" /etc/nginx/sites-available/testsite.conf
assert_cmd_ok "FPM pool has the overridden pm.max_children" grep -q "pm.max_children = 20" /etc/php/8.3/fpm/pool.d/testsite.conf
assert_cmd_ok "FPM pool has the php_ini override" grep -q "php_admin_value\[max_execution_time\] = 45" /etc/php/8.3/fpm/pool.d/testsite.conf
out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "MAX_EXEC=45" "php_ini override actually applies at runtime, not just written to the pool file"

step "ops-owned nginx extra (not from the client repo)"
printf 'location = /extra-probe { default_type text/plain; return 200 extra-ok; }\n' \
    > /etc/nginx/ddeploy-extra/testsite.conf
chown root:root /etc/nginx/ddeploy-extra/testsite.conf
chmod 644 /etc/nginx/ddeploy-extra/testsite.conf
./provision.sh deploy testsite
sleep 1
assert_contains "$(cat /etc/nginx/sites-available/testsite.conf)" "include /etc/nginx/ddeploy-extra/testsite.conf;" "ops-owned extra is included, not copied from the repo"
extra_out="$(curl -sSk --resolve "testsite.staging.ddeploy.test:443:127.0.0.1" "https://testsite.staging.ddeploy.test/extra-probe")"
assert_contains "$extra_out" "extra-ok" "ops extra location is reachable"

step "raw nginx from the client repo is refused (redirect injection)"
WORK="$(mktemp -d)"
git clone -q "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
printf '  - from: /pwn\n    to: "/; return 200;"\n' >> "$WORK/.ddeploy/config.yaml"
git -C "$WORK" add -A
git -C "$WORK" commit -q -am 'poison redirect'
git -C "$WORK" push -q origin main
rm -rf "$WORK"
assert_cmd_fails "deploy refuses a redirect target that would inject nginx directives" ./provision.sh deploy testsite
out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "MARKER=v1" "failed extras deploy left the live tree serving v1"
WORK="$(mktemp -d)"
git clone -q "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
git -C "$WORK" revert --no-edit HEAD
git -C "$WORK" push -q origin main
rm -rf "$WORK"

# --- S3: a poisoned database.name must not reach mysql ------------------

step "poisoned database.name is refused (SQL identifier allowlist)"
WORK="$(mktemp -d)"
git clone -q "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
sed -i 's/^  name: testsite$/  name: "testsite'"'"'; DROP DATABASE mysql;--"/' "$WORK/.ddev/config.yaml"
git -C "$WORK" commit -q -am 'poison database.name'
git -C "$WORK" push -q origin main
rm -rf "$WORK"
assert_cmd_fails "deploy refuses a database.name that would inject SQL" ./provision.sh deploy testsite
out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "MARKER=v1" "failed identifier deploy left the live tree serving v1"
mysql_still="$(mysql --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" -N -B -e "SHOW DATABASES LIKE 'mysql';")"
[[ -n "$mysql_still" ]] && pass "mysql system database still exists after the poisoned deploy" \
    || fail "mysql system database is gone — identifier interpolation ran attacker SQL"
WORK="$(mktemp -d)"
git clone -q "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
git -C "$WORK" revert --no-edit HEAD
git -C "$WORK" push -q origin main
rm -rf "$WORK"

# --- deploy re-applies vhost/FPM config, not just provision -------------

step "deploy re-applies vhost/FPM config (not just provision)"
WORK="$(mktemp -d)"
git clone -q "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
sed -i 's/client_max_body_size: 256m/client_max_body_size: 512m/' "$WORK/.ddeploy/config.yaml"
sed -i 's/max_execution_time: 45/max_execution_time: 77/' "$WORK/.ddeploy/config.yaml"
printf 'basic_auth: true\n' >> "$WORK/.ddeploy/config.yaml"
git -C "$WORK" commit -q -am 'config change: body size, php_ini, basic_auth'
git -C "$WORK" push -q origin main
rm -rf "$WORK"

./provision.sh deploy testsite
sleep 1

assert_cmd_ok "vhost picked up the NEW client_max_body_size from a deploy alone" grep -q "client_max_body_size 512m;" /etc/nginx/sites-available/testsite.conf
assert_cmd_ok "FPM pool picked up the NEW php_ini value from a deploy alone" grep -q "php_admin_value\[max_execution_time\] = 77" /etc/php/8.3/fpm/pool.d/testsite.conf
assert_cmd_fails "testsite now requires auth (basic_auth: true took effect via deploy alone)" curl -fsSk --resolve "testsite.staging.ddeploy.test:443:127.0.0.1" "https://testsite.staging.ddeploy.test/"
if [[ -n "$AUTH_PASS" ]]; then
    out="$(curl -fsSk -u "preview:$AUTH_PASS" --resolve "testsite.staging.ddeploy.test:443:127.0.0.1" "https://testsite.staging.ddeploy.test/")"
    assert_contains "$out" "MAX_EXEC=77" "authenticated request confirms the new php_ini value is live"
else
    fail "never captured AUTH_PASS"
fi

# Revert basic_auth (every later step in this script curls testsite
# without credentials) — leave body-size/php_ini at their new values,
# nothing downstream checks those specific numbers again.
WORK="$(mktemp -d)"
git clone -q "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
sed -i '/^basic_auth: true$/d' "$WORK/.ddeploy/config.yaml"
git -C "$WORK" commit -q -am 'revert basic_auth'
git -C "$WORK" push -q origin main
rm -rf "$WORK"
./provision.sh deploy testsite
sleep 1
out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "DB_OK" "basic_auth reverted, testsite reachable without credentials again"

step "deploy re-applies FPM pool on a PHP-version bump, and cleans up the stale one"
WORK="$(mktemp -d)"
git clone -q "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
sed -i 's/php_version: "8.3"/php_version: "8.2"/' "$WORK/.ddev/config.yaml"
git -C "$WORK" commit -q -am 'bump php_version to 8.2'
git -C "$WORK" push -q origin main
rm -rf "$WORK"

./provision.sh deploy testsite
sleep 1

assert_file_exists "/etc/php/8.2/fpm/pool.d/testsite.conf" "new php8.2 FPM pool installed from a deploy alone"
assert_file_absent "/etc/php/8.3/fpm/pool.d/testsite.conf" "stale php8.3 pool cleaned up (same /run/php/testsite.sock path would otherwise conflict)"
assert_cmd_ok "php8.2-fpm is active" systemctl is-active --quiet php8.2-fpm
out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "DB_OK" "site still serves correctly after the PHP-version bump"

# Revert to 8.3 — every later assertion in this script assumes that pool path.
WORK="$(mktemp -d)"
git clone -q "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
sed -i 's/php_version: "8.2"/php_version: "8.3"/' "$WORK/.ddev/config.yaml"
git -C "$WORK" commit -q -am 'revert php_version to 8.3'
git -C "$WORK" push -q origin main
rm -rf "$WORK"
./provision.sh deploy testsite
sleep 1
assert_file_exists "/etc/php/8.3/fpm/pool.d/testsite.conf" "reverted back to a php8.3 FPM pool"
assert_file_absent "/etc/php/8.2/fpm/pool.d/testsite.conf" "php8.2 pool cleaned up again on revert"

# --- probe row for backup/restore-database verification ---------------

mysql --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" testsite \
    -e "CREATE TABLE probe (id INT); INSERT INTO probe VALUES (1);"
pass "seeded a probe row directly in the real database (for the restore check below)"

# --- deploy (via GitHub webhook, then CLI rollback) --------------------

step "webhook: HMAC and routing guards"
BODY="$(mktemp)"
write_github_push main "$BODY"
code="$(curl -sS -o /tmp/hook-body -w "%{http_code}" -k \
    --resolve "${HOOK_HOST}:443:127.0.0.1" \
    -X POST "https://${HOOK_HOST}/github" \
    -H "Content-Type: application/json" \
    --data-binary @"$BODY")"
[[ "$code" == "401" ]] && pass "unsigned POST /github is 401" || fail "unsigned POST /github returned $code, expected 401"

sig="$(hmac_sha256_file "$BODY")"
code="$(curl -sS -o /tmp/hook-body -w "%{http_code}" -k \
    --resolve "${HOOK_HOST}:443:127.0.0.1" \
    -X POST "https://${HOOK_HOST}/bitbucket" \
    -H "Content-Type: application/json" \
    -H "X-Hub-Signature-256: $sig" \
    -H "X-Event-Key: repo:push" \
    --data-binary @"$BODY")"
[[ "$code" == "401" ]] && pass "GitHub HMAC header on POST /bitbucket is 401" || fail "wrong-path HMAC returned $code, expected 401"

python3 -c 'import json,sys; json.dump({"zen":"ok"}, sys.stdout)' > "$BODY"
code="$(post_hook /github X-Hub-Signature-256 X-GitHub-Event ping "$BODY")"
[[ "$code" == "202" ]] && pass "GitHub ping is 202" || fail "GitHub ping returned $code, expected 202"

python3 -c '
import json, sys
json.dump({"ref":"refs/heads/main","deleted":False,"after":"0"*40,
           "repository":{"clone_url":"https://github.com/other/nope.git"}}, sys.stdout)
' > "$BODY"
code="$(post_hook /github X-Hub-Signature-256 X-GitHub-Event push "$BODY")"
[[ "$code" == "202" ]] && pass "unknown repo push is 202" || fail "unknown repo returned $code"
flush_hooks
out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "MARKER=v1" "unknown-repo webhook did not deploy testsite"

write_github_pr opened feature-a "attacker/fork" "$BODY"
code="$(post_hook /github X-Hub-Signature-256 X-GitHub-Event pull_request "$BODY")"
[[ "$code" == "202" ]] && pass "fork pull_request is 202 (ignored)" || fail "fork PR returned $code"
flush_hooks
assert_file_absent "/etc/nginx/sites-enabled/testsite-feature-a.conf" "fork PR did not provision a preview"

write_bitbucket_pr pullrequest:created feature-a "{fork}" "{src}" "$BODY"
code="$(post_hook /bitbucket X-Hub-Signature X-Event-Key pullrequest:created "$BODY")"
[[ "$code" == "202" ]] && pass "Bitbucket fork PR is 202 (ignored)" || fail "Bitbucket fork PR returned $code"
flush_hooks
assert_file_absent "/etc/nginx/sites-enabled/testsite-feature-a.conf" "Bitbucket fork PR did not provision a preview"
rm -f "$BODY"

# --- PR preview comments (mock GitHub/Bitbucket API) -------------------

step "preview PR comments (upsert + webhook wiring)"
python3 - <<'PY' &
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import json
import re

log = Path("/tmp/ddeploy-comment-sink.jsonl")
# Comments are keyed by PR so a later webhook on PR 42 does not
# "find" the helper-test comment that was posted on PR 99.
github = {}
bitbucket = {}
github_ids = {}
bitbucket_ids = {}
counters = {"gh": 1, "bb": 1}

class H(BaseHTTPRequestHandler):
    def _plain(self):
        return self.path.split("?", 1)[0]

    def _auth(self):
        h = self.headers.get("Authorization") or ""
        return h.startswith("Bearer ") or h.startswith("Basic ")

    def _read(self):
        n = int(self.headers.get("Content-Length") or "0")
        return self.rfile.read(n)

    def _json(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _record(self, method):
        body = self._read()
        with log.open("ab") as f:
            f.write(("%s %s " % (method, self.path)).encode() + body + b"\n")
        return body

    def _gh_pr(self):
        m = re.search(r"/issues/(\d+)/comments/?$", self._plain())
        return m.group(1) if m else None

    def _bb_pr(self):
        m = re.search(r"/pullrequests/(\d+)/comments/?$", self._plain())
        return m.group(1) if m else None

    def do_GET(self):
        if not self._auth():
            self._json(401, {"message": "unauthorized"})
            return
        pr = self._gh_pr()
        if pr is not None:
            self._json(200, github.get(pr, []))
            return
        pr = self._bb_pr()
        if pr is not None:
            self._json(200, {"values": bitbucket.get(pr, [])})
            return
        self._json(404, {"message": "not found"})

    def do_POST(self):
        if not self._auth():
            self._json(401, {"message": "unauthorized"})
            return
        raw = self._record("POST")
        data = json.loads(raw.decode() or "{}")
        pr = self._gh_pr()
        if pr is not None:
            item = {"id": counters["gh"], "body": data.get("body") or ""}
            counters["gh"] += 1
            github.setdefault(pr, []).append(item)
            github_ids[item["id"]] = item
            self._json(201, item)
            return
        pr = self._bb_pr()
        if pr is not None:
            item = {"id": counters["bb"], "content": data.get("content") or {}}
            counters["bb"] += 1
            bitbucket.setdefault(pr, []).append(item)
            bitbucket_ids[item["id"]] = item
            self._json(201, item)
            return
        self._json(404, {"message": "not found"})

    def do_PATCH(self):
        if not self._auth():
            self._json(401, {"message": "unauthorized"})
            return
        raw = self._record("PATCH")
        data = json.loads(raw.decode() or "{}")
        cid = int(self._plain().rstrip("/").rsplit("/", 1)[-1])
        item = github_ids.get(cid)
        if item is not None:
            item["body"] = data.get("body") or item.get("body")
            self._json(200, item)
            return
        self._json(404, {"message": "not found"})

    def do_PUT(self):
        if not self._auth():
            self._json(401, {"message": "unauthorized"})
            return
        raw = self._record("PUT")
        data = json.loads(raw.decode() or "{}")
        cid = int(self._plain().rstrip("/").rsplit("/", 1)[-1])
        item = bitbucket_ids.get(cid)
        if item is not None:
            item["content"] = data.get("content") or item.get("content")
            self._json(200, item)
            return
        self._json(404, {"message": "not found"})

    def log_message(self, *_args):
        pass

HTTPServer(("127.0.0.1", 8801), H).serve_forever()
PY
COMMENT_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsS -o /dev/null -H 'Authorization: Bearer t' "http://127.0.0.1:8801/repos/x/y/issues/1/comments" && break
    sleep 0.2
done
: >/tmp/ddeploy-comment-sink.jsonl
cat > /etc/ddeploy/preview-comment.env <<'EOF'
GITHUB_TOKEN="test-github-token"
GITHUB_API="http://127.0.0.1:8801"
BITBUCKET_USER="bb"
BITBUCKET_APP_PASSWORD="bbpass"
BITBUCKET_API="http://127.0.0.1:8801"
EOF
chmod 600 /etc/ddeploy/preview-comment.env
grep -q '^PREVIEW_COMMENT_CREDENTIALS=' /opt/ddeploy/provisioner.conf \
    || echo 'PREVIEW_COMMENT_CREDENTIALS="/etc/ddeploy/preview-comment.env"' >> /opt/ddeploy/provisioner.conf

# Direct helper: first call POSTs, second call PATCHes the same marker.
export PREVIEW_COMMENT_CREDENTIALS="/etc/ddeploy/preview-comment.env"
source lib/preview_comment.sh
comment_preview_pr github testsite 99 github.com/gitfixture/testsite
comment_preview_pr github testsite 99 github.com/gitfixture/testsite
sink="$(cat /tmp/ddeploy-comment-sink.jsonl 2>/dev/null || true)"
assert_contains "$sink" "POST /repos/gitfixture/testsite/issues/99/comments" "first preview comment is a POST"
assert_contains "$sink" "PATCH /repos/gitfixture/testsite/issues/comments/1" "second preview comment updates the existing one"
assert_contains "$sink" "https://testsite.staging.ddeploy.test" "preview comment includes the site URL"
assert_contains "$sink" "<!-- ddeploy-preview -->" "preview comment carries the idempotency marker"
comment_preview_pr github testsite '1; curl evil' github.com/gitfixture/testsite
lines="$(grep -c . /tmp/ddeploy-comment-sink.jsonl 2>/dev/null || echo 0)"
[[ "$lines" == "2" ]] && pass "non-numeric PR id is refused (no extra API call)" || fail "poison PR id still posted (sink lines=$lines)"
comment_preview_pr github testsite 99 evil.example/gitfixture/testsite
[[ "$(grep -c . /tmp/ddeploy-comment-sink.jsonl 2>/dev/null || echo 0)" == "2" ]] \
    && pass "comment repo is taken from github.com urls, not an arbitrary host" \
    || fail "arbitrary host still posted"
: >/tmp/ddeploy-comment-sink.jsonl

# bitbucket_upsert is a genuinely separate code path from github_upsert
# (different endpoint shape, PUT not PATCH, {"content":{"raw":...}} not
# {"body":...}, Basic auth from user+app-password) — the mock server
# above already handles Bitbucket-shaped routes, but nothing called this
# until now, so none of that was ever actually exercised.
comment_preview_pr bitbucket testsite 77 bitbucket.org/gitfixture/testsite
comment_preview_pr bitbucket testsite 77 bitbucket.org/gitfixture/testsite
bb_sink="$(cat /tmp/ddeploy-comment-sink.jsonl 2>/dev/null || true)"
assert_contains "$bb_sink" "POST /2.0/repositories/gitfixture/testsite/pullrequests/77/comments" "first Bitbucket preview comment is a POST"
assert_contains "$bb_sink" "PUT /2.0/repositories/gitfixture/testsite/pullrequests/77/comments/1" "second Bitbucket preview comment updates the existing one (PUT, not PATCH)"
assert_contains "$bb_sink" "https://testsite.staging.ddeploy.test" "Bitbucket preview comment includes the site URL"
assert_contains "$bb_sink" "<!-- ddeploy-preview -->" "Bitbucket preview comment carries the idempotency marker"
: >/tmp/ddeploy-comment-sink.jsonl

# Only the Bitbucket path exercises a successful (same-repo) PR above —
# this covers the GitHub side of parse_github's pull_request handling
# end to end, not just the fork-rejection branch.
step "provision-preview via GitHub webhook (same-repo PR, success path)"
WORK="$(mktemp -d)"
git clone -q "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
git -C "$WORK" checkout -q -b feature-gh
sed -i 's/MARKER=v1/MARKER=preview-gh-v1/' "$WORK/web/index.php"
git -C "$WORK" commit -q -am 'gh preview branch'
git -C "$WORK" push -q origin feature-gh
rm -rf "$WORK"

BODY="$(mktemp)"
write_github_pr opened feature-gh "gitfixture/testsite" "$BODY"
code="$(post_hook /github X-Hub-Signature-256 X-GitHub-Event pull_request "$BODY")"
[[ "$code" == "202" ]] && pass "same-repo GitHub pull_request accepted" || fail "same-repo GitHub PR returned $code"
flush_hooks
sleep 1
rm -f "$BODY"

GH_PREVIEW=testsite-feature-gh
assert_file_exists "/etc/nginx/sites-enabled/$GH_PREVIEW.conf" "GitHub-webhook provision-preview created the preview vhost"
sink="$(cat /tmp/ddeploy-comment-sink.jsonl 2>/dev/null || true)"
assert_contains "$sink" "POST /repos/gitfixture/testsite/issues/42/comments" "GitHub webhook posted a preview comment on PR 42"
assert_contains "$sink" "https://testsite-feature-gh.staging.ddeploy.test" "GitHub preview comment has the preview URL"
if [[ -n "$AUTH_PASS" ]]; then
    out="$(curl -fsSk -u "preview:$AUTH_PASS" --resolve "$GH_PREVIEW.staging.ddeploy.test:443:127.0.0.1" "https://$GH_PREVIEW.staging.ddeploy.test/")"
    assert_contains "$out" "MARKER=preview-gh-v1" "GitHub-webhook preview serves the feature-gh branch"
else
    fail "never captured the generated basic-auth password from init's output"
fi

# Self-contained: this branch/preview isn't touched by anything else in
# this script, so clean both up rather than leaving them for the rest of
# the run (which only manages testsite and testsite-feature-a).
./provision.sh remove-preview testsite feature-gh --purge-files
git -C "$BARE" branch -D feature-gh >/dev/null
assert_file_absent "/etc/nginx/sites-enabled/$GH_PREVIEW.conf" "GitHub-webhook preview cleaned up"

step "deploy testsite via GitHub webhook (atomic release, git pull --ff-only)"
V1_SHA="$(git -C "$LIVE" log -1 --format=%H)"
WORK="$(mktemp -d)"
git clone -q "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
sed -i 's/MARKER=v1/MARKER=v2/' "$WORK/web/index.php"
git -C "$WORK" commit -q -am 'v2'
git -C "$WORK" push -q origin main
rm -rf "$WORK"

write_github_push main "$BODY"
code="$(post_hook /github X-Hub-Signature-256 X-GitHub-Event push "$BODY")"
[[ "$code" == "202" ]] && pass "GitHub push webhook accepted" || fail "GitHub push returned $code, expected 202"
flush_hooks
sleep 1

out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "MARKER=v2" "webhook deploy pulled the new commit (GIT_DEPLOY_KEY end to end)"
V2_RELEASE="$(readlink -f "$LIVE")"
assert_cmd_ok "v2 is a distinct release directory" test -d "$V2_RELEASE"
rm -f "$BODY"

step "deploy --rollback / --history"
history_out="$(./provision.sh deploy testsite --history)"
assert_contains "$history_out" "v2" "deploy history lists the v2 commit"

./provision.sh deploy testsite --rollback
sleep 1
out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "MARKER=v1" "deploy --rollback (implicit, no sha) moved the code back to v1"
assert_cmd_ok "rollback retargeted current away from the v2 release" test "$V2_RELEASE" != "$(readlink -f "$LIVE")"
assert_contains "$(grep MARKER= "$V2_RELEASE/web/index.php")" "MARKER=v2" "the previous release tree is left intact (not git-reset in place)"

n_releases="$(find "$SITES_ROOT/testsite/releases" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l)"
[[ "$n_releases" -le 3 ]] && pass "RELEASES_KEEP=3 pruned extras (have $n_releases)" || fail "expected at most 3 releases, have $n_releases"

./provision.sh deploy testsite --rollback "$V1_SHA"
sleep 1
out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "MARKER=v1" "deploy --rollback <sha> (explicit) works too"

# Roll forward again with a plain deploy — proves a rollback doesn't
# strand the site: origin/main is still at v2, and a normal
# deploy builds a new release that fast-forwards right back up to it.
# Also leaves testsite at v2 for every later step in this script.
./provision.sh deploy testsite
sleep 1
out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "MARKER=v2" "a plain deploy after a rollback pulls forward again"

step "deploy_branch: operator-side branch override (provision --branch)"

# A new branch off main's current tip, with distinct content so a curl
# can tell it apart from main.
WORK="$(mktemp -d)"
git clone -q "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
git -C "$WORK" checkout -q -b alt-main
sed -i 's/MARKER=v2/MARKER=alt-branch-v1/' "$WORK/web/index.php"
git -C "$WORK" commit -q -am 'alt-main v1'
git -C "$WORK" push -q origin alt-main:alt-main
rm -rf "$WORK"

# Operator sets the override — server-side only, no repo commit. testsite
# is already provisioned (tracking main), so this just persists the
# setting; it does not touch git by itself (only `deploy` does that).
resolved_out="$(./provision.sh provision testsite --branch alt-main 2>&1)"
assert_contains "$resolved_out" "deploy_branch=alt-main" "provision echoes the resolved deploy_branch"
head_branch="$(git -C "$LIVE" rev-parse --abbrev-ref HEAD)"
[[ "$head_branch" == "main" ]] && pass "setting the override alone does not touch git yet" || fail "expected HEAD still main, got '$head_branch'"

# The override is visible immediately (it's a local file, not something
# that has to be pulled), so — unlike a repo-committed setting — even the
# very FIRST push to the newly-configured branch is recognized right
# away: the webhook branch-matcher checks it alongside HEAD.
BODY="$(mktemp)"
write_github_push alt-main "$BODY"
code="$(post_hook /github X-Hub-Signature-256 X-GitHub-Event push "$BODY")"
[[ "$code" == "202" ]] && pass "GitHub push to alt-main accepted" || fail "GitHub push to alt-main returned $code, expected 202"
flush_hooks
sleep 1
rm -f "$BODY"
out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "MARKER=alt-branch-v1" "the push was matched via the override (not ignored) and switched the site onto it"
head_branch="$(git -C "$LIVE" rev-parse --abbrev-ref HEAD)"
[[ "$head_branch" == "alt-main" ]] && pass "site's checkout is now on alt-main" || fail "expected HEAD alt-main, got '$head_branch'"

# Once already on the configured branch, later pushes to it are an
# ordinary pull --ff-only, not another switch.
WORK="$(mktemp -d)"
git clone -q --branch alt-main "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
sed -i 's/MARKER=alt-branch-v1/MARKER=alt-branch-v2/' "$WORK/web/index.php"
git -C "$WORK" commit -q -am 'alt-main v2'
git -C "$WORK" push -q origin alt-main
rm -rf "$WORK"

BODY="$(mktemp)"
write_github_push alt-main "$BODY"
code="$(post_hook /github X-Hub-Signature-256 X-GitHub-Event push "$BODY")"
[[ "$code" == "202" ]] && pass "GitHub push to alt-main (2nd) accepted" || fail "GitHub push to alt-main (2nd) returned $code"
flush_hooks
sleep 1
rm -f "$BODY"
out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "MARKER=alt-branch-v2" "a later push to the already-tracked branch pulls forward normally"

# Switch back to main — same mechanism, no repo commit needed.
./provision.sh provision testsite --branch main
./provision.sh deploy testsite
sleep 1
head_branch="$(git -C "$LIVE" rev-parse --abbrev-ref HEAD)"
[[ "$head_branch" == "main" ]] && pass "--branch main switched the site back" || fail "expected HEAD main, got '$head_branch'"
out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "MARKER=v2" "back on main, serving its content again"

# --clear-branch removes the override entirely, leaving testsite clean
# for every later step in this script.
./provision.sh provision testsite --clear-branch
resolved_out="$(./provision.sh provision testsite 2>&1)"
assert_not_contains "$resolved_out" "deploy_branch=" "--clear-branch removed the override"

step "override: operator-side config override wins over .ddeploy/config.yaml"

# testsite's repo-side .ddeploy/config.yaml has client_max_body_size:
# 512m as of the "deploy re-applies vhost/FPM config" step above — no
# repo commit needed for this test, the override alone should win.
./provision.sh override testsite client_max_body_size=333m
show_out="$(./provision.sh override testsite --show)"
assert_contains "$show_out" "client_max_body_size: 333m" "override --show reflects what was just set"

./provision.sh deploy testsite
sleep 1
assert_cmd_ok "vhost uses the OVERRIDE value (333m), not the repo's 512m" grep -q "client_max_body_size 333m;" /etc/nginx/sites-available/testsite.conf

# Unsetting it falls back to whatever the repo itself declares (512m),
# not the built-in server default (64m) — the override is a 3rd,
# highest-precedence tier, not a replacement for the other two.
./provision.sh override testsite --unset client_max_body_size
./provision.sh deploy testsite
sleep 1
assert_cmd_ok "vhost falls back to the repo's own 512m once the override is unset" grep -q "client_max_body_size 512m;" /etc/nginx/sites-available/testsite.conf

# An unknown key and an invalid value are both rejected outright, not
# silently ignored or written as garbage.
assert_cmd_fails "override refuses an unknown key" ./provision.sh override testsite not_a_real_key=x
assert_cmd_fails "override refuses an invalid value for a validated key" ./provision.sh override testsite basic_auth=maybe

./provision.sh override testsite --clear
show_out="$(./provision.sh override testsite --show 2>&1)"
assert_contains "$show_out" "no overrides set" "override --clear removed everything"

# --- branch preview (shared mode, the default) -------------------------

step "provision-preview testsite feature-a via Bitbucket webhook"
BODY="$(mktemp)"
write_bitbucket_pr pullrequest:created feature-a "{src}" "{src}" "$BODY"
code="$(post_hook /bitbucket X-Hub-Signature X-Event-Key pullrequest:created "$BODY")"
[[ "$code" == "202" ]] && pass "Bitbucket pullrequest:created accepted" || fail "Bitbucket PR created returned $code"
flush_hooks
sleep 1
rm -f "$BODY"

PREVIEW=testsite-feature-a
assert_cmd_fails "shared-mode preview has NO Linux user of its own" id -u "www-$PREVIEW"
assert_file_exists "/etc/nginx/sites-enabled/$PREVIEW.conf" "preview vhost enabled"

assert_cmd_fails "preview requires auth (no credentials -> non-2xx)" curl -fsSk --resolve "$PREVIEW.staging.ddeploy.test:443:127.0.0.1" "https://$PREVIEW.staging.ddeploy.test/"
assert_cmd_ok "auth_exempt_paths entry (/health) bypasses auth, no credentials needed" curl -fsSk --resolve "$PREVIEW.staging.ddeploy.test:443:127.0.0.1" "https://$PREVIEW.staging.ddeploy.test/health"
if [[ -n "$AUTH_PASS" ]]; then
    out="$(curl -fsSk -u "preview:$AUTH_PASS" --resolve "$PREVIEW.staging.ddeploy.test:443:127.0.0.1" "https://$PREVIEW.staging.ddeploy.test/")"
    assert_contains "$out" "MARKER=preview-v1" "preview serves the feature-a branch"
    assert_contains "$out" "DB_OK" "preview's DB link (shared mode) actually works, not just resolves"
else
    fail "never captured the generated basic-auth password from init's output"
fi

list_out="$(./provision.sh list)"
assert_contains "$list_out" "testsite/feature-a (shared)" "list shows the preview, shared mode, resolved to its parent"

step "deploy-preview testsite feature-a via Bitbucket webhook"
WORK="$(mktemp -d)"
git clone -q --branch feature-a "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
sed -i 's/MARKER=preview-v1/MARKER=preview-v2/' "$WORK/web/index.php"
git -C "$WORK" commit -q -am 'preview v2'
git -C "$WORK" push -q origin feature-a
rm -rf "$WORK"

BODY="$(mktemp)"
write_bitbucket_pr pullrequest:updated feature-a "{src}" "{src}" "$BODY"
code="$(post_hook /bitbucket X-Hub-Signature X-Event-Key pullrequest:updated "$BODY")"
[[ "$code" == "202" ]] && pass "Bitbucket pullrequest:updated accepted" || fail "Bitbucket PR updated returned $code"
flush_hooks
sleep 1
out="$(curl -fsSk -u "preview:$AUTH_PASS" --resolve "$PREVIEW.staging.ddeploy.test:443:127.0.0.1" "https://$PREVIEW.staging.ddeploy.test/")"
assert_contains "$out" "MARKER=preview-v2" "webhook deploy-preview fetch+reset picked up the new commit"
sink="$(cat /tmp/ddeploy-comment-sink.jsonl 2>/dev/null || true)"
assert_contains "$sink" "POST /2.0/repositories/gitfixture/testsite/pullrequests/7/comments" "Bitbucket webhook posted a preview comment on PR 7"
assert_contains "$sink" "PUT /2.0/repositories/gitfixture/testsite/pullrequests/7/comments/" "Bitbucket deploy-preview updated the existing PR comment (PUT, not a duplicate POST)"
assert_contains "$sink" "https://testsite-feature-a.staging.ddeploy.test" "Bitbucket preview comment has the preview URL"
kill "$COMMENT_PID" 2>/dev/null || true
wait "$COMMENT_PID" 2>/dev/null || true
rm -f "$BODY"

# --- backup / restore, against real object storage (MinIO) -------------

step "backup-uploads / backup-database (all sites)"
echo "hello from uploads" > "$LIVE/private-uploads/marker.txt"
mkdir -p "$LIVE/private-uploads/exclude-me"
echo "should never leave this box" > "$LIVE/private-uploads/exclude-me/secret.txt"

backup_out="$(./provision.sh backup-uploads 2>&1)"
assert_contains "$backup_out" "skipping 'testsite-feature-a'" "backup-uploads skips the shared-mode preview"
assert_not_contains "$backup_out" "backup-uploads failed" "backup-uploads succeeded for testsite"

db_backup_out="$(./provision.sh backup-database 2>&1)"
assert_contains "$db_backup_out" "skipping 'testsite-feature-a'" "backup-database skips the shared-mode preview"
assert_not_contains "$db_backup_out" "backup-database failed" "backup-database succeeded for testsite"

remote="$(backup_remote_spec)"
uploads_listing="$(rclone lsf "${remote}/testsite/private-uploads/" 2>/dev/null || true)"
assert_contains "$uploads_listing" "marker.txt" "uploaded marker.txt is actually in object storage"
exclude_listing="$(rclone lsf "${remote}/testsite/private-uploads/exclude-me/" 2>/dev/null || true)"
assert_not_contains "$exclude_listing" "secret.txt" "backup_exclude kept the excluded file out of object storage"
db_listing="$(rclone lsf "${remote}/testsite/db/" 2>/dev/null || true)"
[[ -n "$db_listing" ]] && pass "a database dump landed in object storage" || fail "no database dump found in object storage"

step "restore-uploads / restore-database"
rm -f "$LIVE/private-uploads/marker.txt"
mysql --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" testsite -e "DROP TABLE probe;"

./provision.sh restore-uploads testsite --yes
assert_file_exists "$LIVE/private-uploads/marker.txt" "restore-uploads brought the file back"

./provision.sh restore-database testsite --yes
probe_count="$(mysql --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" -N -B testsite -e "SELECT COUNT(*) FROM probe;")"
[[ "$probe_count" == "1" ]] && pass "restore-database brought the probe row back" || fail "probe table missing/empty after restore (got: $probe_count)"

step "restore-database --from-file (local dump, e.g. a client-provided export)"
DUMP="$(mktemp)"
cat > "$DUMP" <<'SQL'
DROP TABLE IF EXISTS probe;
CREATE TABLE probe (id INT);
INSERT INTO probe VALUES (42);
SQL
./provision.sh restore-database testsite --from-file "$DUMP" --yes
rm -f "$DUMP"
probe_val="$(mysql --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" -N -B testsite -e "SELECT id FROM probe;")"
[[ "$probe_val" == "42" ]] && pass "restore-database --from-file loaded the local dump" || fail "probe table wrong/missing after --from-file (got: $probe_val)"

# --- security: a dump is imported as the site's own scoped DB user, ------
# --- never admin (S4) -----------------------------------------------------
# load_sql_dump_into_db (lib/db.sh) used to connect as admin/root and
# just set the default schema — any SQL in the dump ran with full admin
# privileges. It now connects as the target database's own user, whose
# grant (db_ensure) is scoped to exactly that one database with no WITH
# GRANT OPTION. Calls the sourced function directly (this script already
# `source`s lib/db.sh) rather than going through provision.sh, so the
# test is exactly what a client-provided --from-file export exercises,
# without touching preview machinery.

step "a malicious dump's admin-only statements fail, instead of quietly succeeding"
TS_DB_PASS="$(grep '^DB_PASSWORD=' "$LIVE/.env" | cut -d= -f2-)"
[[ -n "$TS_DB_PASS" ]] || fail "couldn't read testsite's own DB_PASSWORD from .env for this test"

EVIL_DUMP="$(mktemp)"
cat > "$EVIL_DUMP" <<'SQL'
DROP TABLE IF EXISTS probe;
CREATE TABLE probe (id INT);
INSERT INTO probe VALUES (7);
CREATE USER 'evilpwn'@'%' IDENTIFIED BY 'pwned';
GRANT ALL PRIVILEGES ON *.* TO 'evilpwn'@'%' WITH GRANT OPTION;
SQL
if load_sql_dump_into_db "$EVIL_DUMP" testsite testsite "$TS_DB_PASS"; then
    fail "malicious dump imported successfully — CREATE USER/GRANT should have failed under the scoped site user"
else
    pass "malicious dump's CREATE USER/GRANT failed (scoped user has no such privilege)"
fi
rm -f "$EVIL_DUMP"

evil_exists="$(mysql --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE User='evilpwn';")"
[[ "$evil_exists" == "0" ]] && pass "no 'evilpwn' user was created anywhere on the server" || fail "'evilpwn' user exists — admin-level escalation from a dump succeeded"

step "a dump with a view/routine DEFINER still imports cleanly (DEFINER stripped to CURRENT_USER)"
DEFINER_DUMP="$(mktemp)"
cat > "$DEFINER_DUMP" <<'SQL'
DROP TABLE IF EXISTS probe;
CREATE TABLE probe (id INT);
INSERT INTO probe VALUES (55);
DROP VIEW IF EXISTS probe_view;
CREATE DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW probe_view AS SELECT id FROM probe;
SQL
if load_sql_dump_into_db "$DEFINER_DUMP" testsite testsite "$TS_DB_PASS"; then
    pass "dump containing a DEFINER=\`root\`@\`localhost\` view imported as the scoped user"
else
    fail "import failed — DEFINER stripping isn't working, a legitimate backup (dumped by admin) would no longer restore"
fi
rm -f "$DEFINER_DUMP"
view_val="$(mysql --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" -N -B testsite -e "SELECT id FROM probe_view;")"
[[ "$view_val" == "55" ]] && pass "the view (with its DEFINER neutralized) actually works" || fail "probe_view missing/wrong after import (got: $view_val)"
mysql --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" testsite -e "DROP VIEW IF EXISTS probe_view; DROP TABLE IF EXISTS probe;"

# --- prune-previews: real git-ls-remote-exit-code path ------------------

step "prune-previews (feature-a branch deleted upstream)"
git -C "$BARE" branch -D feature-a >/dev/null
./provision.sh prune-previews
assert_file_absent "/etc/nginx/sites-enabled/$PREVIEW.conf" "prune-previews removed the preview whose branch is gone"

# --- persistent files: survive removal, restore automatically ----------

step "persistent files: survive --purge-files without --purge-persistent"
db_pass_before="$(grep '^DB_PASSWORD=' "$LIVE/.env" | cut -d= -f2-)"
[[ -n "$db_pass_before" ]] || fail "couldn't read DB_PASSWORD from testsite's .env before removal"

./provision.sh remove testsite --purge-files
assert_file_absent "/etc/nginx/sites-enabled/testsite.conf" "vhost removed"
assert_file_absent "$SITES_ROOT/testsite" "checkout removed"
assert_file_exists "$PERSISTENT_ROOT/testsite/private-uploads/marker.txt" "uploads survived the purge (no --purge-persistent)"
assert_file_exists "$PERSISTENT_ROOT/testsite/.env" "DB credential file survived the purge"
assert_contains "$(cat "$PERSISTENT_ROOT/testsite/shared-notes.txt")" "important client note" "persistent_files entry's content survived the purge"
db_exists="$(mysql --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" -N -B -e "SHOW DATABASES LIKE 'testsite';")"
[[ -n "$db_exists" ]] && pass "database untouched (no --purge-db)" || fail "database was dropped without --purge-db"

step "provision re-links and restores automatically"
./provision.sh provision testsite "$REPO_URL"
sleep 1
out="$(curl_site testsite.staging.ddeploy.test)"
assert_contains "$out" "DB_OK" "re-provisioned site reconnects to its DB"
assert_file_exists "$LIVE/private-uploads/marker.txt" "uploads immediately present again, no restore step needed"
db_pass_after="$(grep '^DB_PASSWORD=' "$LIVE/.env" | cut -d= -f2-)"
[[ "$db_pass_before" == "$db_pass_after" ]] && pass "same DB password reused — zero credential churn" || fail "DB password changed across remove/re-provision (before='$db_pass_before' after='$db_pass_after')"

# --- doctor (health check) ----------------------------------------------

step "doctor testsite"
doctor_out="$(./provision.sh doctor testsite)" && doctor_exit=0 || doctor_exit=$?
echo "$doctor_out"
if [[ "$doctor_exit" -eq 0 ]]; then
    pass "doctor exits 0 for a healthy site (no failed checks)"
else
    fail "doctor exited $doctor_exit for a healthy site"
fi
assert_contains "$doctor_out" "nginx config" "doctor: checks nginx config"
assert_contains "$doctor_out" "database server" "doctor: checks the database server itself (admin connection)"
assert_contains "$doctor_out" "testsite: vhost" "doctor: checks testsite's vhost"
assert_contains "$doctor_out" "testsite: php8.3-fpm" "doctor: checks testsite's PHP-FPM pool"
assert_contains "$doctor_out" "reachable as 'testsite'" "doctor: testsite database check succeeds with its OWN credentials, not the admin ones"
assert_contains "$doctor_out" "testsite: last deploy" "doctor: reports last deploy info"
assert_contains "$doctor_out" "testsite: cert (custom domain)" "doctor: checks the custom-domain cert too"
assert_contains "$doctor_out" "[ok]   webhook listener" "doctor: reports webhook listener status explicitly"
assert_contains "$doctor_out" "[ok]   uploads backup" "doctor: reports uploads backup on/off explicitly"
assert_contains "$doctor_out" "[ok]   database backup" "doctor: reports database backup on/off explicitly"
assert_contains "$doctor_out" "[ok]   prune-previews" "doctor: reports prune-previews on/off explicitly"
assert_contains "$doctor_out" "object storage" "doctor: tests object storage connectivity when backups are enabled"
assert_contains "$doctor_out" "reachable" "doctor: object storage reachability test passed"
assert_contains "$doctor_out" "testsite: database backups" "doctor: reports per-site recoverable database dump count"
assert_contains "$doctor_out" "recoverable dump(s)" "doctor: database backup check found the real dump uploaded earlier"
assert_contains "$doctor_out" "testsite: uploads backup" "doctor: reports per-site uploads backup status"
assert_contains "$doctor_out" "has synced content" "doctor: uploads backup check found the real marker.txt uploaded earlier"

step "doctor (fleet-wide, no name)"
fleet_out="$(./provision.sh doctor)" || true
assert_contains "$fleet_out" "testsite: vhost" "doctor (fleet-wide): includes testsite among every provisioned site"

assert_cmd_fails "doctor errors cleanly on an unknown site name" ./provision.sh doctor not-a-real-site

# --- failure paging (NOTIFY_WEBHOOK) ------------------------------------

step "notify_failure POSTs JSON and respects cooldown"
source lib/notify.sh
rm -f /tmp/ddeploy-notify-sink.jsonl
python3 - <<'PY' &
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
out = Path("/tmp/ddeploy-notify-sink.jsonl")

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or "0")
        body = self.rfile.read(n)
        with out.open("ab") as f:
            f.write(body + b"\n")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")
    def log_message(self, *_args):
        pass

HTTPServer(("127.0.0.1", 8799), H).serve_forever()
PY
NOTIFY_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsS -o /dev/null http://127.0.0.1:8799/ && break
    sleep 0.2
done
: >/tmp/ddeploy-notify-sink.jsonl

rm -rf /var/lib/ddeploy/notify
NOTIFY_WEBHOOK="http://127.0.0.1:8799/notify"
NOTIFY_COOLDOWN=3600
notify_failure backup-uploads testsite "rclone 403 for tests"
sleep 0.2
sink="$(cat /tmp/ddeploy-notify-sink.jsonl 2>/dev/null || true)"
assert_contains "$sink" "backup-uploads" "notify POST includes the command"
assert_contains "$sink" "testsite" "notify POST includes the site"
assert_contains "$sink" '"text"' "notify POST has Slack text"
assert_contains "$sink" '"content"' "notify POST has Discord content"

notify_failure backup-uploads testsite "second failure same hour"
sleep 0.2
lines="$(grep -c . /tmp/ddeploy-notify-sink.jsonl 2>/dev/null || echo 0)"
[[ "$lines" == "1" ]] && pass "cooldown skipped the second page" || fail "cooldown did not skip (sink lines=$lines)"

NOTIFY_COOLDOWN=0
notify_failure backup-uploads testsite "cooldown disabled"
sleep 0.2
lines="$(grep -c . /tmp/ddeploy-notify-sink.jsonl 2>/dev/null || echo 0)"
[[ "$lines" == "2" ]] && pass "NOTIFY_COOLDOWN=0 sends again" || fail "expected 2 sink lines, got $lines"

NOTIFY_WEBHOOK=""
notify_failure backup-uploads testsite "should be silent"
sleep 0.2
lines="$(grep -c . /tmp/ddeploy-notify-sink.jsonl 2>/dev/null || echo 0)"
[[ "$lines" == "2" ]] && pass "empty NOTIFY_WEBHOOK is a no-op" || fail "empty URL still posted (sink lines=$lines)"

kill "$NOTIFY_PID" 2>/dev/null || true
wait "$NOTIFY_PID" 2>/dev/null || true
rm -rf /var/lib/ddeploy/notify /tmp/ddeploy-notify-sink.jsonl

# --- queue workers & scheduled tasks -------------------------------------

step "queue_workers: persistent, supervised, restarted on deploy"
WORK="$(mktemp -d)"
git clone -q "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
cat >> "$WORK/.ddeploy/config.yaml" <<'YAML'
queue_workers:
  - sleep 1000
  - sleep 2000
schedule:
  - cron: "* * * * *"
    cmd: echo schedule-ran-$(date +%s) >> /tmp/schedule-marker.txt
YAML
git -C "$WORK" commit -q -am 'add queue_workers + schedule'
git -C "$WORK" push -q origin main
rm -rf "$WORK"

./provision.sh deploy testsite
sleep 1

assert_cmd_ok "worker #0 is active" systemctl is-active --quiet ddeploy-worker-testsite-0
assert_cmd_ok "worker #1 is active" systemctl is-active --quiet ddeploy-worker-testsite-1
worker_user="$(ps -o user= -C sleep | sort -u | tr -d ' ' | paste -sd, -)"
assert_contains "$worker_user" "www-testsite" "queue worker actually runs as www-testsite, not root"
assert_cmd_fails "queue worker does NOT run as root" pgrep -u root -f 'sleep 1000'

cron_content="$(cat /etc/cron.d/ddeploy-site-testsite)"
# root, not www-testsite, is the cron.d line's own user field — www-testsite
# is created with --shell /usr/sbin/nologin, and cron silently refuses to
# exec anything for a user whose shell isn't a real one. `runuser -u`
# sidesteps that; the job still actually runs as www-testsite.
assert_contains "$cron_content" "* * * * * root runuser -u www-testsite --" "schedule cron.d entry runs via runuser -u www-testsite"
assert_contains "$cron_content" "$LOG_DIR/testsite.log" "schedule output is redirected into the site's own log"

pid_before="$(systemctl show -p MainPID --value ddeploy-worker-testsite-0)"

step "redeploy restarts workers onto the new release (must not keep serving stale code)"
./provision.sh deploy testsite
sleep 1
pid_after="$(systemctl show -p MainPID --value ddeploy-worker-testsite-0)"
[[ "$pid_before" != "$pid_after" && -n "$pid_after" && "$pid_after" != "0" ]] \
    && pass "worker #0 was actually restarted on redeploy (pid $pid_before -> $pid_after)" \
    || fail "worker #0 pid unchanged across redeploy ($pid_before -> $pid_after) — stale code would keep running"
assert_cmd_ok "worker #0 still active after redeploy" systemctl is-active --quiet ddeploy-worker-testsite-0

step "shrinking queue_workers removes the stale one, keeps the rest running"
WORK="$(mktemp -d)"
git clone -q "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
python3 - "$WORK/.ddeploy/config.yaml" <<'PY'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines()
out, skip = [], False
for line in lines:
    if line.startswith("queue_workers:"):
        skip = True
        out.append("queue_workers:")
        out.append("  - sleep 1000")
        continue
    if skip and line.startswith("  - "):
        continue
    skip = False
    out.append(line)
open(path, "w").write("\n".join(out) + "\n")
PY
git -C "$WORK" commit -q -am 'shrink queue_workers to 1 entry'
git -C "$WORK" push -q origin main
rm -rf "$WORK"

./provision.sh deploy testsite
sleep 1
assert_cmd_ok "worker #0 still active after shrinking" systemctl is-active --quiet ddeploy-worker-testsite-0
assert_file_absent "/etc/systemd/system/ddeploy-worker-testsite-1.service" "stale worker #1's unit file was removed"
assert_cmd_fails "worker #1 is no longer active" systemctl is-active --quiet ddeploy-worker-testsite-1

step "scheduled task actually fires (waiting for the next minute boundary)"
rm -f /tmp/schedule-marker.txt
sleep 65
assert_file_exists "/tmp/schedule-marker.txt" "cron actually ran the scheduled command within a minute"
assert_contains "$(cat /tmp/schedule-marker.txt 2>/dev/null)" "schedule-ran-" "scheduled command's real output landed where expected"
rm -f /tmp/schedule-marker.txt

# --- git access: no standing key copy, but a private VCS dep still works ---
# Security-audit finding: GIT_DEPLOY_KEY used to be copied into every
# site's own $HOME/.ssh so hooks could authenticate as www-<name> — a
# standing, always-readable copy of a fleet-wide key. It's now a
# transient per-deploy ssh-agent instead (lib/git_access.sh). Proves both
# halves: the old copy is really gone, AND a hooks.post-start step that
# needs git/SSH (a private composer/VCS dependency, say) still works,
# with zero client-project changes beyond declaring the hook.

step "hooks.post-start step reaches a private repo via the per-deploy ssh-agent, no key file ever lands in www-testsite's home"
rm -rf /tmp/private-lib-probe
WORK="$(mktemp -d)"
git clone -q "$BARE" "$WORK"
git -C "$WORK" config user.email 'test@ddeploy.test'
git -C "$WORK" config user.name 'ddeploy test'
cat >> "$WORK/.ddev/config.yaml" <<'YAML'
hooks:
  post-start:
    - exec: "rm -rf /tmp/private-lib-probe && git clone ssh://gitfixture@127.0.0.1/srv/git/private-lib.git /tmp/private-lib-probe"
YAML
git -C "$WORK" commit -q -am 'add a hooks.post-start step that clones a private repo'
git -C "$WORK" push -q origin main
rm -rf "$WORK"

./provision.sh deploy testsite

assert_file_exists "/tmp/private-lib-probe/MARKER" "private repo was actually cloned by the hooks.post-start step"
assert_contains "$(cat /tmp/private-lib-probe/MARKER 2>/dev/null)" "private-lib-ok" "cloned private repo's real content landed where expected"
clone_owner="$(stat -c %U /tmp/private-lib-probe 2>/dev/null)"
[[ "$clone_owner" == "www-testsite" ]] \
    && pass "private repo was cloned AS www-testsite, not root" \
    || fail "private repo clone owned by '$clone_owner', expected www-testsite"

assert_file_absent "$SITES_ROOT/testsite/.ssh" "no www-testsite .ssh directory exists after deploy"
key_copies="$(find "$SITES_ROOT" -iname 'deploy_key' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$key_copies" == "0" ]] \
    && pass "no copy of GIT_DEPLOY_KEY exists anywhere under \$SITES_ROOT" \
    || fail "found $key_copies copy/copies of the deploy key under \$SITES_ROOT — should be zero"
assert_cmd_fails "no lingering ssh-agent process for www-testsite after deploy" pgrep -u www-testsite ssh-agent

rm -rf /tmp/private-lib-probe

# --- final cleanup, everything purged ------------------------------------

step "remove testsite --purge-db --purge-files --purge-persistent"
./provision.sh remove testsite --purge-db --purge-files --purge-persistent

assert_file_absent "/etc/nginx/sites-enabled/testsite.conf" "vhost removed"
assert_file_absent "/etc/php/8.3/fpm/pool.d/testsite.conf" "FPM pool removed"
assert_cmd_fails "www-testsite Linux user removed" id -u www-testsite
assert_file_absent "$SITES_ROOT/testsite" "site directory removed"
assert_file_absent "$PERSISTENT_ROOT/testsite" "persistent store removed (--purge-persistent)"
db_exists="$(mysql --defaults-extra-file="$DB_ADMIN_CREDENTIALS" -h "$DB_HOST" -N -B -e "SHOW DATABASES LIKE 'testsite';")"
[[ -z "$db_exists" ]] && pass "database dropped" || fail "database 'testsite' still exists after --purge-db"
assert_cmd_ok "nginx config still valid after removal" nginx -t
assert_cmd_fails "worker #0's unit is gone after remove" systemctl is-active --quiet ddeploy-worker-testsite-0
assert_file_absent "/etc/systemd/system/ddeploy-worker-testsite-0.service" "worker #0's unit file removed"
assert_file_absent "/etc/cron.d/ddeploy-site-testsite" "schedule cron.d file removed"

echo "ALL LIFECYCLE CHECKS PASSED" | tee -a "$STEP_LOG"
