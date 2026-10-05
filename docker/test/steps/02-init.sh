#!/usr/bin/env bash
# Runs INSIDE the web container. provisioner.conf was written by
# test/run.sh (CLOUDFLARE_PROXIED=true, real Cloudflare IP-ranges fetch,
# mocked certbot/ufw — see docker/README.md).
set -euo pipefail
cd /opt/ddeploy
source docker/test/lib.sh

step "init"
init_out="$(./provision.sh init 2>&1 | tee -a "$STEP_LOG")"

# S12: init no longer logs the plaintext password at all — it writes it
# straight to this root-only file instead (see lib/cmd_init.sh). Assert
# both: the file exists with the right permissions, and the password
# itself never appeared in init's own output.
assert_file_exists /etc/ddeploy/basic-auth-password "basic-auth password file exists (not logged)"
auth_file_mode="$(stat -L -c %a /etc/ddeploy/basic-auth-password)"
[[ "$auth_file_mode" == "600" ]] && pass "basic-auth password file is 600" || fail "basic-auth password file mode is $auth_file_mode, expected 600"
captured_pass="$(cat /etc/ddeploy/basic-auth-password)"
assert_not_contains "$init_out" "$captured_pass" "the actual password never appeared in init's own log output"

step "init: checks"
assert_cmd_ok "nginx is active" systemctl is-active --quiet nginx
assert_cmd_ok "php8.3-fpm is active" systemctl is-active --quiet php8.3-fpm
assert_cmd_ok "yq is the Go (mikefarah) build" bash -c "yq --version | grep -qi mikefarah"
assert_file_exists "/etc/letsencrypt/live/staging.ddeploy.test/fullchain.pem" "wildcard cert issued (mocked certbot)"
assert_cmd_ok "known_hosts has github.com (real ssh-keyscan)" grep -q github.com /etc/ssh/ssh_known_hosts
assert_file_exists "/etc/nginx/conf.d/cloudflare-realip.conf" "Cloudflare real-IP config written (real Cloudflare ranges fetch)"
realip_lines="$(grep -c set_real_ip_from /etc/nginx/conf.d/cloudflare-realip.conf || true)"
[[ "$realip_lines" -gt 0 ]] && pass "real-IP config has $realip_lines Cloudflare ranges" || fail "real-IP config has no ranges"
assert_contains "$(cat /etc/nginx/conf.d/ddeploy-server-names.conf 2>/dev/null)" "server_names_hash_bucket_size 128" "room for long preview hostnames in nginx"
assert_cmd_ok "composer installed" command -v composer
assert_file_exists "/etc/nginx/htpasswd/default" "default basic-auth htpasswd generated"
assert_cmd_ok "default htpasswd has 'preview' user" grep -q '^preview:' /etc/nginx/htpasswd/default
assert_cmd_ok "mock ufw recorded ssh allow rule" grep -q 'comment .ssh.\|comment ssh' /var/lib/ddeploy-mock-ufw/rules
assert_cmd_ok "webhook listener is running" systemctl is-active --quiet ddeploy-hook
assert_file_exists "/usr/local/lib/ddeploy/hookparse.py" "hookparse.py deployed alongside the listener (needed at import time)"
assert_file_exists "/etc/ddeploy/webhook.secret" "webhook HMAC secret generated"
# A4: root:root 600, not root:ddeploy-hook 640 — the listener (running
# as ddeploy-hook) must not be able to read this at all; only hook-worker
# (root) does, via hook/verify_and_spool.py.
secret_owner="$(stat -c %U:%G /etc/ddeploy/webhook.secret)"
[[ "$secret_owner" == "root:root" ]] && pass "webhook secret is root:root" || fail "webhook secret owned by $secret_owner, expected root:root"
secret_mode="$(stat -c %a /etc/ddeploy/webhook.secret)"
[[ "$secret_mode" == "600" ]] && pass "webhook secret is 600" || fail "webhook secret mode is $secret_mode, expected 600"
assert_cmd_fails "ddeploy-hook user cannot read the webhook secret" sudo -u ddeploy-hook cat /etc/ddeploy/webhook.secret
assert_cmd_ok "webhook vhost enabled" test -f /etc/nginx/sites-enabled/ddeploy-hook.conf
assert_cmd_ok "ops nginx extra dir exists (root-owned, not from a client repo)" test -d /etc/nginx/ddeploy-extra
hook_health="$(curl -fsSk --resolve "hooks.staging.ddeploy.test:443:127.0.0.1" "https://hooks.staging.ddeploy.test/health")"
assert_contains "$hook_health" "ok" "webhook /health through the vhost"

step "init: the ddeploy command"
assert_cmd_ok "ddeploy installed, root-owned, executable" test -x /usr/local/bin/ddeploy
[[ "$(stat -c %U /usr/local/bin/ddeploy)" == "root" ]] && pass "ddeploy wrapper is root-owned" || fail "ddeploy wrapper owned by $(stat -c %U /usr/local/bin/ddeploy)"
assert_file_exists /etc/bash_completion.d/ddeploy "bash completion installed"
out="$(cd / && ddeploy list 2>&1)"
assert_not_contains "$out" "error" "ddeploy runs the checkout from any directory"
out="$(sudo -u deploy ddeploy --help 2>&1)"
assert_contains "$out" "usage: ddeploy" "help works for a non-root user without sudo"
# A sudoers rule scoped to provision.sh alone (the kind a CI deploy key
# gets) must keep matching when going through the wrapper — it sudo's
# provision.sh itself, never the wrapper.
echo 'deploy ALL=(root) NOPASSWD: /opt/ddeploy/provision.sh' > /etc/sudoers.d/ddeploy-test
chmod 440 /etc/sudoers.d/ddeploy-test
assert_cmd_ok "non-root ddeploy re-runs itself through a provision.sh-scoped sudo rule" sudo -u deploy ddeploy list
rm -f /etc/sudoers.d/ddeploy-test
completions="$(bash -c 'source /etc/bash_completion.d/ddeploy; COMP_WORDS=(ddeploy dep); COMP_CWORD=1; _ddeploy; echo "${COMPREPLY[*]}"')"
assert_contains "$completions" "deploy-preview" "completion offers commands from the live usage text"

step "init: /etc/ddeploy, /var/lib/ddeploy, /var/log/ddeploy"
[[ "$(stat -c '%a' /var/lib/ddeploy)" == "751" ]] && pass "/var/lib/ddeploy is 751 (traversable, not listable)" || fail "/var/lib/ddeploy is $(stat -c '%a' /var/lib/ddeploy)"
[[ "$(stat -c '%U:%G %a' /var/lib/ddeploy/generated)" == "root:root 711" ]] && pass "generated/ is root 711" || fail "generated/ is $(stat -c '%U:%G %a' /var/lib/ddeploy/generated)"
[[ "$(stat -c '%U:%G %a' /var/log/ddeploy)" == "root:adm 750" ]] && pass "/var/log/ddeploy is root:adm 750" || fail "/var/log/ddeploy is $(stat -c '%U:%G %a' /var/log/ddeploy)"
assert_file_exists /etc/logrotate.d/ddeploy "logrotate config installed"
if command -v logrotate >/dev/null 2>&1; then
    assert_cmd_ok "logrotate accepts it" logrotate -d /etc/logrotate.d/ddeploy
fi
assert_cmd_fails "a non-root user can't list the state directory" sudo -u nobody ls /var/lib/ddeploy/generated

step "init: idempotent re-run"
before="$(md5sum /etc/nginx/htpasswd/default | cut -d' ' -f1)"
./provision.sh init
after="$(md5sum /etc/nginx/htpasswd/default | cut -d' ' -f1)"
[[ "$before" == "$after" ]] && pass "basic-auth credentials unchanged on re-run" || fail "basic-auth credentials regenerated on re-run"

echo "ALL INIT CHECKS PASSED" | tee -a "$STEP_LOG"
