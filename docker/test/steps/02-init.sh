#!/usr/bin/env bash
# Runs INSIDE the web container. provisioner.conf was written by
# test/run.sh (CLOUDFLARE_PROXIED=true, real Cloudflare IP-ranges fetch,
# mocked certbot/ufw — see docker/README.md).
set -euo pipefail
cd /opt/ddeploy
source docker/test/lib.sh

step "init"
init_out="$(./provision.sh init 2>&1 | tee -a "$STEP_LOG")"
grep -oP 'password=\K\S+' <<< "$init_out" | head -n1 > /etc/ddeploy/basic-auth-password
pass "captured generated basic-auth password for later checks"

step "init: checks"
assert_cmd_ok "nginx is active" systemctl is-active --quiet nginx
assert_cmd_ok "php8.3-fpm is active" systemctl is-active --quiet php8.3-fpm
assert_cmd_ok "yq is the Go (mikefarah) build" bash -c "yq --version | grep -qi mikefarah"
assert_file_exists "/etc/letsencrypt/live/staging.ddeploy.test/fullchain.pem" "wildcard cert issued (mocked certbot)"
assert_cmd_ok "known_hosts has github.com (real ssh-keyscan)" grep -q github.com /etc/ssh/ssh_known_hosts
assert_file_exists "/etc/nginx/conf.d/cloudflare-realip.conf" "Cloudflare real-IP config written (real Cloudflare ranges fetch)"
realip_lines="$(grep -c set_real_ip_from /etc/nginx/conf.d/cloudflare-realip.conf || true)"
[[ "$realip_lines" -gt 0 ]] && pass "real-IP config has $realip_lines Cloudflare ranges" || fail "real-IP config has no ranges"
assert_cmd_ok "composer installed" command -v composer
assert_file_exists "/etc/nginx/htpasswd/default" "default basic-auth htpasswd generated"
assert_cmd_ok "default htpasswd has 'preview' user" grep -q '^preview:' /etc/nginx/htpasswd/default
assert_cmd_ok "mock ufw recorded ssh allow rule" grep -q 'comment .ssh.\|comment ssh' /var/lib/ddeploy-mock-ufw/rules
assert_cmd_ok "webhook listener is running" systemctl is-active --quiet ddeploy-hook
assert_file_exists "/etc/ddeploy/webhook.secret" "webhook HMAC secret generated"
assert_cmd_ok "webhook vhost enabled" test -f /etc/nginx/sites-enabled/ddeploy-hook.conf
assert_cmd_ok "ops nginx extra dir exists (root-owned, not from a client repo)" test -d /etc/nginx/ddeploy-extra
hook_health="$(curl -fsSk --resolve "hooks.staging.ddeploy.test:443:127.0.0.1" "https://hooks.staging.ddeploy.test/health")"
assert_contains "$hook_health" "ok" "webhook /health through the vhost"

step "init: idempotent re-run"
before="$(md5sum /etc/nginx/htpasswd/default | cut -d' ' -f1)"
./provision.sh init
after="$(md5sum /etc/nginx/htpasswd/default | cut -d' ' -f1)"
[[ "$before" == "$after" ]] && pass "basic-auth credentials unchanged on re-run" || fail "basic-auth credentials regenerated on re-run"

echo "ALL INIT CHECKS PASSED" | tee -a "$STEP_LOG"
