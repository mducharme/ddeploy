#!/usr/bin/env bash
# Host-side orchestrator for the ddeploy docker test harness. Brings up
# two systemd-enabled Ubuntu 24.04 containers (a dedicated DB server and a
# web server — see docker/docker-compose.yml) plus a MinIO instance for
# object storage, wires them together the way a real deployment's
# provisioner.conf would, and runs the full site lifecycle against them.
# See docker/README.md for what's real vs mocked and why.
#
# Usage: docker/test/run.sh [--keep]
#   --keep   leave the containers running after a pass/fail instead of
#            tearing them down (for `docker compose exec` poking around)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GEN_DIR="$DOCKER_DIR/test/generated"
PROJECT="ddeploytest"
COMPOSE=(docker compose -p "$PROJECT" -f "$DOCKER_DIR/docker-compose.yml")

KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

mkdir -p "$GEN_DIR"

log()  { printf '\033[36m[run]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[run FAIL]\033[0m %s\n' "$*"; exit 1; }

cleanup() {
    if [[ "$KEEP" -eq 1 ]]; then
        log "leaving containers up (--keep) — 'docker compose -p $PROJECT -f $DOCKER_DIR/docker-compose.yml down -v' to tear down"
    else
        log "tearing down"
        "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

wait_for() {
    local desc="$1" tries="$2"; shift 2
    local i=0
    until "$@" >/dev/null 2>&1; do
        i=$((i + 1))
        [[ "$i" -ge "$tries" ]] && fail "timed out waiting for: $desc"
        sleep 2
    done
    log "ready: $desc"
}

systemd_ready() {
    local svc="$1" state
    state="$("${COMPOSE[@]}" exec -T "$svc" systemctl is-system-running 2>/dev/null || true)"
    [[ "$state" == "running" || "$state" == "degraded" ]]
}

# --- build + up ----------------------------------------------------------

log "building images"
"${COMPOSE[@]}" build

log "starting containers"
"${COMPOSE[@]}" up -d

wait_for "dbhost systemd" 60 systemd_ready dbhost
wait_for "web systemd" 60 systemd_ready web
wait_for "minio health" 60 "${COMPOSE[@]}" exec -T web curl -fsS http://objectstore:9000/minio/health/live

# --- wire the two containers together, like a real provisioner.conf would --

WEB_ID="$("${COMPOSE[@]}" ps -q web)"
WEB_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$WEB_ID")"
[[ -n "$WEB_IP" ]] || fail "couldn't determine web container's IP"
log "web container IP: $WEB_IP"

DB_ADMIN_CREDENTIALS_PATH="/etc/ddeploy/db-admin.cnf"

cat > "$GEN_DIR/provisioner.db.conf" <<EOF
DB_ADMIN_CREDENTIALS="$DB_ADMIN_CREDENTIALS_PATH"
DB_ALLOWED_HOSTS="$WEB_IP"
EOF

cat > "$GEN_DIR/provisioner.web.conf" <<EOF
BASE_DOMAIN="staging.ddeploy.test"
SITES_ROOT="/home/deploy/sites"
CF_CREDENTIALS="/etc/ddeploy/cf-credentials.ini"
CERT_EMAIL="test@ddeploy.test"
BASELINE_PHP="8.3"
DEFAULT_PHP="8.3"
BASIC_AUTH_DEFAULT="false"
BASIC_AUTH_CREDENTIALS="/etc/nginx/htpasswd/default"
GIT_DEPLOY_KEY="/etc/ddeploy/git_deploy_key"
CLOUDFLARE_PROXIED="true"
PHP_EXTENSIONS="cli mysql mbstring xml curl zip gd"
DB_HOST="dbhost"
DB_ADMIN_CREDENTIALS="$DB_ADMIN_CREDENTIALS_PATH"
DB_GRANT_HOST="$WEB_IP"
BACKUP_ENABLED="true"
BACKUP_CREDENTIALS="/etc/ddeploy/backup-credentials.env"
BACKUP_BUCKET="ddeploy-test"
BACKUP_SCHEDULE="17 * * * *"
DB_BACKUP_ENABLED="true"
DB_BACKUP_SCHEDULE="23 * * * *"
DB_BACKUP_RETENTION_DAYS="7"
PREVIEW_DB_MODE="shared"
PREVIEW_SEED="true"
PREVIEW_PRUNE_ENABLED="false"
EOF

cat > "$GEN_DIR/backup-credentials.env" <<'EOF'
BACKUP_ENDPOINT="http://objectstore:9000"
BACKUP_ACCESS_KEY="ddeployminio"
BACKUP_SECRET_KEY="ddeployminiosecret"
EOF

cat > "$GEN_DIR/cf-credentials.ini" <<'EOF'
dns_cloudflare_api_token = dummy-not-used-certbot-is-mocked
EOF

"${COMPOSE[@]}" exec -T dbhost mkdir -p /etc/ddeploy
"${COMPOSE[@]}" exec -T web mkdir -p /etc/ddeploy

"${COMPOSE[@]}" cp "$GEN_DIR/provisioner.db.conf" dbhost:/opt/ddeploy/provisioner.conf
"${COMPOSE[@]}" cp "$GEN_DIR/provisioner.web.conf" web:/opt/ddeploy/provisioner.conf
"${COMPOSE[@]}" cp "$GEN_DIR/backup-credentials.env" web:/etc/ddeploy/backup-credentials.env
"${COMPOSE[@]}" cp "$GEN_DIR/cf-credentials.ini" web:/etc/ddeploy/cf-credentials.ini
log "provisioner.conf + credential files written into both containers"

# --- init-db, then copy the admin credentials it generates over to web ---

"${COMPOSE[@]}" exec -T dbhost bash /opt/ddeploy/docker/test/steps/01-init-db.sh

"${COMPOSE[@]}" cp "dbhost:$DB_ADMIN_CREDENTIALS_PATH" "$GEN_DIR/db-admin.cnf"
"${COMPOSE[@]}" cp "$GEN_DIR/db-admin.cnf" "web:$DB_ADMIN_CREDENTIALS_PATH"
log "DB admin credentials copied from dbhost to web"

# --- web: fixtures, init, full lifecycle ---------------------------------

"${COMPOSE[@]}" exec -T web bash /opt/ddeploy/docker/test/steps/00-fixtures.sh
"${COMPOSE[@]}" exec -T web bash /opt/ddeploy/docker/test/steps/02-init.sh
"${COMPOSE[@]}" exec -T web bash /opt/ddeploy/docker/test/steps/03-lifecycle.sh

log "ALL SMOKE TESTS PASSED"
