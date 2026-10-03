#!/usr/bin/env bash
# Runs INSIDE the web container, after 03-lifecycle.sh (which leaves no
# sites behind). The `api` subcommand the web UI drives ddeploy through
# (lib/cmd_api.sh), and the pieces under it: init-web's sudoers rule,
# detached runs, the event log, per-run output logs and per-site locking.
set -euo pipefail
cd /opt/ddeploy
source docker/test/lib.sh

REPO_URL="ssh://gitfixture@127.0.0.1/srv/git/testsite.git"
WEB_USER=ddeploy-web

# $1 python expression over `d` (the parsed JSON on stdin) to print.
jq_py() { python3 -c 'import json,sys; d=json.load(sys.stdin); v=eval(sys.argv[1]); print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1"; }

# $1 run id, $2 timeout seconds. Waits for a final event; prints its phase.
wait_run() {
    local id="$1" timeout="${2:-300}" i phase
    for ((i = 0; i < timeout; i++)); do
        phase="$(ddeploy api run show "$id" 2>/dev/null \
            | jq_py '[e["phase"] for e in d["events"] if e["phase"] != "started"][-1:] or ""' || true)"
        if [[ -n "$phase" && "$phase" != '""' && "$phase" != "[]" ]]; then
            python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0])' "$phase"
            return 0
        fi
        sleep 1
    done
    echo timeout
}

run_id_of() { jq_py 'd["run_id"]'; }

# 03-lifecycle.sh's last testsite commit has a deploy step that clones
# into this path as www-testsite; a re-created www-testsite gets a new
# uid and couldn't remove the old one's copy.
rm -rf /tmp/private-lib-probe

step "api: refuses what it doesn't allow"
out="$(ddeploy api remove testsite 2>/dev/null || true)"
assert_contains "$out" '"code":"unknown_verb"' "verb outside the allowlist (remove) refused with a JSON error"
out="$(ddeploy api run start provision testsite "$REPO_URL" --actor a@b.c --deploy-cmd id 2>/dev/null || true)"
assert_contains "$out" "option '--deploy-cmd' is not allowed" "--deploy-cmd refused"
out="$(ddeploy api run start provision testsite 'file:///srv/git/testsite.git' --actor a@b.c 2>/dev/null || true)"
assert_contains "$out" '"code":"bad_request"' "file:// repo URL refused"
out="$(ddeploy api run start deploy testsite --actor 'not an email' 2>/dev/null || true)"
assert_contains "$out" "--actor must be an email address" "invalid --actor refused"
out="$(ddeploy api logs ../../etc/passwd 2>/dev/null || true)"
assert_contains "$out" '"code":"bad_request"' "path traversal in a log name refused"
out="$(ddeploy api run log ../../../etc/shadow 2>/dev/null || true)"
assert_contains "$out" "invalid run id" "path traversal in a run id refused"
assert_cmd_fails "api exits nonzero on error" ddeploy api site nope

step "api: filters that match nothing are empty results, not errors"
assert_contains "$(ddeploy api events --project no-such-project)" '"events":[]' "events --project with no previews"
assert_contains "$(ddeploy api events --run 20990101T000000Z-abcdef)" '"events":[]' "events --run with no match"
assert_contains "$(ddeploy api previews no-such-project)" '"previews":[]' "previews of a project with none"

step "api: info"
out="$(ddeploy api info)"
assert_contains "$(jq_py 'd["api_version"]' <<< "$out")" "1" "api_version is 1"
assert_contains "$(jq_py 'd["base_domain"]' <<< "$out")" "staging.ddeploy.test" "base_domain reported"

step "api: inspect-repo"
out="$(ddeploy api inspect-repo "$REPO_URL")"
assert_contains "$(jq_py 'd["reachable"]' <<< "$out")" "true" "fixture repo reachable with the deploy key"
assert_contains "$(jq_py 'd["default_branch"]' <<< "$out")" "main" "default branch detected"
assert_contains "$(jq_py 'd["detected"]["ddev"]["name"]' <<< "$out")" "testsite" ".ddev name detected"
out="$(ddeploy api inspect-repo ssh://gitfixture@127.0.0.1/srv/git/missing.git)"
assert_contains "$(jq_py 'd["reachable"]' <<< "$out")" "false" "missing repo reported unreachable, not an error"

step "api: a failed provision is a failed event with its error"
id="$(ddeploy api run start provision wrongname "$REPO_URL" --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 120)" "failed" "provision under a name that doesn't match .ddev's name fails"
out="$(ddeploy api run show "$id")"
assert_contains "$(jq_py 'd["events"][-1]["error"]' <<< "$out")" "does not match directory name" "error line carried in the event"
assert_contains "$(jq_py 'd["meta"]["actor"]' <<< "$out")" "admin@example.com" "run metadata keeps the actor"
out="$(ddeploy api run start provision wrongname ssh://gitfixture@127.0.0.1/srv/git/other.git --actor a@b.c 2>/dev/null || true)"
assert_contains "$out" '"code":"conflict"' "leftover checkout of another repo can't be reused"
ddeploy remove wrongname --purge-files >/dev/null 2>&1 || rm -rf /home/deploy/sites/wrongname
userdel www-wrongname 2>/dev/null || true

step "api: provision through a detached run"
id="$(ddeploy api run start provision testsite "$REPO_URL" --actor admin@example.com --hostnames alt-testsite | run_id_of)"
if [[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$ ]]; then pass "run id returned ($id)"; else fail "no run id: $id"; fi
assert_contains "$(wait_run "$id" 600)" "succeeded" "provision run succeeded"
out="$(ddeploy api run show "$id")"
assert_contains "$(jq_py 'd["events"][0]["trigger"]' <<< "$out")" "web (admin@example.com)" "trigger attributes the web user"
assert_contains "$(jq_py 'len(d["events"][-1]["to_sha"])' <<< "$out")" "40" "final event carries the deployed SHA"
log="$(ddeploy api run log "$id" | jq_py 'd["text"]')"
assert_contains "$log" "provisioned: https://testsite.staging.ddeploy.test" "full output in the run log"
assert_contains "$(grep 'provision: started' /var/log/ddeploy/testsite.log | tail -n 1)" "(web (admin@example.com))" "site log attributes the web user too"

step "api: sites / site"
out="$(ddeploy api sites)"
assert_contains "$(jq_py '[s["name"] for s in d["sites"]]' <<< "$out")" '"testsite"' "testsite listed"
assert_contains "$(jq_py 'd["sites"][0]["last_event"]["phase"]' <<< "$out")" "succeeded" "newest event inlined"
out="$(ddeploy api site testsite)"
assert_contains "$(jq_py 'd["config"]["hostnames"]' <<< "$out")" "alt-testsite.staging.ddeploy.test" "resolved hostnames"
assert_contains "$(jq_py 'd["config"]["php"]' <<< "$out")" "8.3" "resolved PHP version"
assert_contains "$(jq_py 'len([r for r in d["releases"] if r["current"]])' <<< "$out")" "1" "exactly one current release"
assert_contains "$(jq_py 'len(d["legacy_deploys"]) >= 1' <<< "$out")" "true" ".deploys history included"

step "api: deploys on one site are serialized (per-site lock)"
a="$(ddeploy api run start deploy testsite --actor one@example.com | run_id_of)"
b="$(ddeploy api run start deploy testsite --actor two@example.com | run_id_of)"
assert_contains "$(wait_run "$a" 300)" "succeeded" "first deploy succeeded"
assert_contains "$(wait_run "$b" 300)" "succeeded" "second deploy succeeded"
a_end="$(ddeploy api run show "$a" | jq_py 'd["events"][-1]["ts"]')"
b_start="$(ddeploy api run show "$b" | jq_py 'd["events"][0]["ts"]')"
if [[ ! "$b_start" < "$a_end" ]]; then
    pass "second started after the first finished ($a_end <= $b_start)"
else
    fail "second deploy started ($b_start) before the first finished ($a_end)"
fi
assert_contains "$(ddeploy api run log "$b" | jq_py 'd["text"]')" "waiting for it to finish" "second run logged that it waited"

step "api: CLI runs land in the same history"
SUDO_USER=operator ddeploy deploy testsite >/dev/null 2>&1
out="$(ddeploy api events --site testsite --limit 2)"
assert_contains "$(jq_py 'd["events"][-1]["trigger"]' <<< "$out")" "manual (operator)" "CLI deploy attributed to the sudo user"
cli_run="$(jq_py 'd["events"][-1]["run_id"]' <<< "$out")"
assert_file_exists "/var/log/ddeploy/runs/$cli_run.log" "CLI run got its own output log"
# Every deploy here is the same commit, so roll back to it explicitly
# (an existing release, so no rebuild) — the kind is what's under test.
live_sha="$(git -c safe.directory='*' -C /home/deploy/sites/testsite/current rev-parse HEAD)"
SUDO_USER=operator ddeploy deploy testsite --rollback "$live_sha" >/dev/null 2>&1
assert_contains "$(ddeploy api events --site testsite --limit 1 | jq_py 'd["events"][-1]["kind"]')" "rollback" "rollback recorded as kind=rollback"

step "api: previews and their history"
ddeploy provision-preview testsite alt-main >/dev/null 2>&1
out="$(ddeploy api previews testsite)"
assert_contains "$(jq_py '[p["branch"] for p in d["previews"]]' <<< "$out")" '"alt-main"' "active preview listed"
assert_contains "$(ddeploy api site testsite | jq_py 'd["previews"]')" "testsite-alt-main" "site detail lists its previews"
ddeploy remove-preview testsite alt-main >/dev/null 2>&1
out="$(ddeploy api events --project testsite)"
assert_contains "$(jq_py '[(e["kind"], e["phase"]) for e in d["events"]]' <<< "$out")" '["provision-preview", "succeeded"]' "preview creation in history"
assert_contains "$(jq_py '[(e["kind"], e["phase"]) for e in d["events"]]' <<< "$out")" '["remove-preview", "succeeded"]' "preview removal in history (after its metadata is gone)"
assert_contains "$(ddeploy api previews testsite | jq_py 'd["previews"]')" "[]" "no active previews left"

step "api: doctor"
out="$(ddeploy api doctor)"
assert_contains "$(jq_py '[c["check"] for c in d["server"]["checks"]]' <<< "$out")" "nginx" "server checks present"
assert_contains "$(jq_py '[s["name"] for s in d["sites"]]' <<< "$out")" "testsite" "site checks present"
assert_contains "$(jq_py 'd["sites"][0]["worst"] in ("ok","warn","fail")' <<< "$out")" "true" "worst status computed"

step "api: logs"
out="$(ddeploy api logs)"
assert_contains "$(jq_py '[l["name"] for l in d["logs"] if l["kind"] == "site"]' <<< "$out")" "testsite" "site log listed"
out="$(ddeploy api logs testsite --lines 3)"
size="$(jq_py 'd["size"]' <<< "$out")"
assert_contains "$(jq_py 'd["next_offset"]' <<< "$out")" "$size" "tail read ends at the file size"
echo "2099-01-01T00:00:00Z appended-line" >> /var/log/ddeploy/testsite.log
out="$(ddeploy api logs testsite --offset "$size")"
assert_contains "$(jq_py 'd["text"]' <<< "$out")" "appended-line" "offset read returns only what's new"
out="$(ddeploy api logs testsite --offset 999999999)"
assert_contains "$(jq_py 'd["rotated"]' <<< "$out")" "true" "offset past the end reports rotation and restarts"

step "api: env (values over stdin, never argv)"
out="$(printf 'APP_NAME="My App"\nFEATURE_X=1\n' | ddeploy api env testsite --apply --actor admin@example.com)"
assert_contains "$(jq_py '[e["value"] for e in d["entries"] if e["key"] == "APP_NAME"]' <<< "$out")" '"\"My App\""' "value set, quotes kept verbatim"
assert_contains "$(jq_py '[e["key"] for e in d["entries"] if e["managed"]]' <<< "$out")" "DB_PASSWORD" "ddeploy-managed DB_* keys flagged"
assert_contains "$(grep -c '^FEATURE_X=1$' /home/deploy/persistent/testsite/.env)" "1" "written to the persistent .env"
assert_contains "$(stat -c '%U %a' /home/deploy/persistent/testsite/.env)" "www-testsite 600" ".env keeps its owner and mode"
ddeploy api env testsite --apply --unset FEATURE_X --actor admin@example.com >/dev/null
assert_contains "$(grep -c '^FEATURE_X=' /home/deploy/persistent/testsite/.env || true)" "0" "--unset removes the key"
out="$(echo 'BAD-KEY=1' | ddeploy api env testsite --apply --actor admin@example.com 2>/dev/null || true)"
assert_contains "$out" '"code":"bad_request"' "invalid key refused"
assert_contains "$(ddeploy api events --site testsite --limit 1 | jq_py 'd["events"][-1]["kind"]')" "env-change" "env change recorded in history"

step "api: settings (operator overrides + tracked branch)"
out="$(ddeploy api settings testsite --set client_max_body_size=128m --set 'auth_exempt_paths=/webhook /api' --actor admin@example.com)"
assert_contains "$(jq_py 'd["config"]["settings"]["client_max_body_size"]' <<< "$out")" "128m" "effective value reflects the override"
assert_contains "$(jq_py 'd["overrides"]["auth_exempt_paths"]' <<< "$out")" "/api" "list override stored"
out="$(ddeploy api settings testsite --set db_env_scheme=none --actor admin@example.com 2>/dev/null || true)"
assert_contains "$out" "can't be changed here" "keys outside the web allowlist refused"
out="$(ddeploy api settings testsite --set 'client_max_body_size=1m;x' --actor admin@example.com 2>/dev/null || true)"
assert_contains "$out" "not a plain nginx body size" "values validated like the CLI does"
out="$(ddeploy api settings testsite --branch no-such-branch --actor admin@example.com 2>/dev/null || true)"
assert_contains "$out" "doesn't exist on the remote" "unknown branch refused"
assert_contains "$(ddeploy api settings testsite --branch alt-main --actor admin@example.com | jq_py 'd["deploy_branch"]')" "alt-main" "tracked branch set"
ddeploy api settings testsite --clear-branch --unset client_max_body_size --unset auth_exempt_paths --actor admin@example.com >/dev/null
assert_file_absent /var/lib/ddeploy/generated/testsite.deploy-branch "branch override cleared"
assert_contains "$(ddeploy api branches testsite | jq_py 'd["branches"]')" "alt-main" "branches listed from the remote"

step "api: commits between two deploys"
head_sha="$(git -c safe.directory='*' -C /home/deploy/sites/testsite/current rev-parse HEAD)"
old_sha="$(git -c safe.directory='*' -C /home/deploy/sites/testsite/current rev-parse HEAD~2)"
out="$(ddeploy api commits testsite "$old_sha" "$head_sha")"
assert_contains "$(jq_py 'len(d["ahead"]), len(d["behind"])' <<< "$out")" "(2, 0)" "forward deploy: 2 commits ahead"
assert_contains "$(ddeploy api commits testsite "$head_sha" "$old_sha" | jq_py 'len(d["behind"])')" "2" "rollback: 2 commits behind"

step "api: doctor checks the site answers over HTTP"
assert_contains "$(ddeploy api doctor testsite | jq_py '[c["detail"] for c in d["sites"][0]["checks"] if c["check"] == "http"]')" "GET / -> 200" "http check"

step "api: database — info, dump, import with undo"
assert_contains "$(ddeploy api db credentials testsite | jq_py 'd["user"]')" "testsite" "credentials are the site's own user"
printf 'CREATE TABLE posts (id INT PRIMARY KEY, title VARCHAR(50));\nINSERT INTO posts VALUES (1,"hello"),(2,"world");\n' | gzip > /tmp/api-import.sql.gz
id="$(ddeploy api run start db-import testsite --actor admin@example.com < /tmp/api-import.sql.gz | run_id_of)"
assert_contains "$(wait_run "$id" 120)" "succeeded" "import run succeeded"
out="$(ddeploy api db info testsite)"
assert_contains "$(jq_py '[(t["name"], t["rows"]) for t in d["tables"]]' <<< "$out")" '["posts", 2]' "imported table visible in db info"
undo="$(jq_py '[s["id"] for s in d["snapshots"] if s["reason"] == "pre-import"][0]' <<< "$out")"
assert_contains "$undo" "pre-import" "a pre-import snapshot was taken"
assert_contains "$(find /var/lib/ddeploy/imports -name '*.sql*' | wc -l)" "0" "upload spool file removed after import"
ddeploy api db dump testsite | gunzip > /tmp/api-dump.sql
assert_contains "$(cat /tmp/api-dump.sql)" "INSERT INTO \`posts\`" "dump streams the live database"
out="$(head -c 4096 /bin/ls | ddeploy api run start db-import testsite --actor admin@example.com 2>/dev/null || true)"
assert_contains "$out" "binary content" "a non-SQL upload is refused before anything runs"
id="$(ddeploy api run start db-restore testsite --snapshot "$undo" --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 120)" "succeeded" "restore-from-snapshot run succeeded"
assert_contains "$(ddeploy api db info testsite | jq_py 'd["table_count"]')" "0" "restore really reverts (tables created since are gone)"
assert_contains "$(ddeploy api run show "$id" | jq_py 'd["events"][-1]["kind"]')" "db-restore" "recorded as db-restore"
id="$(ddeploy api run start db-snapshot testsite --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 60)" "succeeded" "manual snapshot"

step "api: rollback and cancel"
id="$(ddeploy api run start rollback testsite --sha "$head_sha" --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 120)" "succeeded" "rollback run succeeded"
assert_contains "$(ddeploy api run show "$id" | jq_py 'd["events"][-1]["kind"]')" "rollback" "recorded as a rollback"
printf '#!/bin/sh\nsleep 60\n' > /etc/ddeploy/hooks/post-deploy.d/99-slow.sh
chmod +x /etc/ddeploy/hooks/post-deploy.d/99-slow.sh
id="$(ddeploy api run start deploy testsite --actor admin@example.com | run_id_of)"
for _ in $(seq 1 30); do
    [[ "$(ddeploy api run show "$id" | jq_py 'len(d["events"])')" -ge 1 ]] && break
    sleep 1
done
sleep 3
ddeploy api run cancel "$id" --actor boss@example.com >/dev/null
assert_contains "$(wait_run "$id" 30)" "failed" "cancelled run ends as failed"
assert_contains "$(ddeploy api run show "$id" | jq_py 'd["events"][-1]["error"], d["cancelled_by"]')" "interrupted" "with an interrupted error and who cancelled it"
rm -f /etc/ddeploy/hooks/post-deploy.d/99-slow.sh
out="$(ddeploy api run cancel "$id" --actor boss@example.com 2>/dev/null || true)"
assert_contains "$out" '"code":"conflict"' "cancelling a finished run is a conflict"

step "api: deploy date, last run, per-site nginx logs, server logs"
out="$(ddeploy api sites)"
assert_contains "$(jq_py 'd["sites"][0]["deployed_at"] is not None' <<< "$out")" "true" "deployed_at reported"
assert_contains "$(jq_py 'd["sites"][0]["last_run"]["kind"] not in ("env-change", "settings-change")' <<< "$out")" "true" "last_run skips config changes"
curl_site testsite.staging.ddeploy.test -o /dev/null || true
curl -sk -o /dev/null --resolve testsite.staging.ddeploy.test:443:127.0.0.1 https://testsite.staging.ddeploy.test/no-such-page || true
assert_file_exists /var/log/nginx/testsite.access.log "the site has its own nginx access log"
out="$(ddeploy api logs)"
assert_contains "$(jq_py '[l["name"] for l in d["logs"]]' <<< "$out")" "testsite.access" "per-site nginx logs listed"
assert_contains "$(jq_py '[l["name"] for l in d["logs"] if l["kind"] == "server"]' <<< "$out")" "_fpm" "PHP-FPM log listed"
assert_contains "$(ddeploy api logs testsite.access --lines 5 | jq_py 'd["text"]')" "/no-such-page" "per-site access log readable"
assert_contains "$(ddeploy api logs nginx_error --lines 1 | jq_py 'd["name"]')" "nginx_error" "server-wide nginx error log readable"
out="$(ddeploy api logs ../../etc/shadow 2>/dev/null || true)"
assert_contains "$out" "invalid log name" "log path traversal refused"

step "api: previews from the web — create, redeploy, remove"
out="$(ddeploy api run start preview-create testsite --branch no-such-branch --actor admin@example.com 2>/dev/null || true)"
assert_contains "$out" "doesn't exist on the remote" "unknown branch refused"
out="$(ddeploy api run start preview-deploy testsite --branch alt-main --actor admin@example.com 2>/dev/null || true)"
assert_contains "$out" '"code":"not_found"' "redeploying a preview that doesn't exist is not_found"
out="$(ddeploy api run start preview-create testsite --branch alt-main --isolated --no-seed --actor admin@example.com)"
assert_contains "$(jq_py 'd["site"]' <<< "$out")" "testsite-alt-main" "run start reports the preview's site name"
id="$(run_id_of <<< "$out")"
assert_contains "$(wait_run "$id" 300)" "succeeded" "preview created"
assert_contains "$(ddeploy api previews testsite | jq_py '[(p["branch"], p["mode"]) for p in d["previews"]]')" '["alt-main", "isolated"]' "isolated preview listed"
assert_contains "$(ddeploy api run show "$id" | jq_py 'd["events"][-1]["trigger"]')" "web (admin@example.com)" "attributed to the web user"
admin_dbs() { mysql --defaults-extra-file=/etc/ddeploy/db-admin.cnf -h dbhost -N -e 'SHOW DATABASES'; }
assert_contains "$(admin_dbs)" "testsite-alt-main" "the isolated preview has its own database"
assert_contains "$(ddeploy api db info testsite-alt-main | jq_py 'd["database"]')" "testsite-alt-main" "...and uses it"
assert_contains "$(ddeploy api db info testsite | jq_py 'd["error"]')" "null" "the project's own database user still works after creating it"
out="$(ddeploy api run start preview-create testsite --branch alt-main --actor admin@example.com 2>/dev/null || true)"
assert_contains "$out" '"code":"conflict"' "a second preview of the same branch is a conflict"
out="$(ddeploy api run start preview-deploy testsite-alt-main --branch main --actor admin@example.com 2>/dev/null || true)"
assert_contains "$out" "is itself a preview" "a preview can't have previews"
id="$(ddeploy api run start preview-deploy testsite --branch alt-main --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 300)" "succeeded" "preview redeployed"
id="$(ddeploy api run start preview-remove testsite --branch alt-main --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 120)" "succeeded" "preview removed"
assert_contains "$(ddeploy api run show "$id" | jq_py '[e["phase"] for e in d["events"]]')" '["started", "succeeded"]' "removal recorded as a run (start and end)"
assert_contains "$(ddeploy api previews testsite | jq_py 'd["previews"]')" "[]" "no previews left"
dbs="$(admin_dbs)"
assert_contains "$dbs" "testsite" "removing an isolated preview keeps the project's database"
assert_not_contains "$dbs" "testsite-alt-main" "...and drops only the preview's own"
assert_contains "$(ddeploy api db info testsite | jq_py 'd["error"]')" "null" "the project's database user still works after removing it"

step "init-web: the web UI's sudoers rule is api-only"
ddeploy init-web >/dev/null 2>&1
assert_file_exists /etc/sudoers.d/ddeploy-web
assert_file_exists /etc/nginx/sites-enabled/ddeploy-web.conf
assert_cmd_ok "nginx accepts the web UI vhost" nginx -t
assert_cmd_ok "sudoers rule passes visudo" visudo -cqf /etc/sudoers.d/ddeploy-web
out="$(sudo -u "$WEB_USER" sudo -n /opt/ddeploy/provision.sh api info)"
assert_contains "$out" '"api_version":1' "$WEB_USER can run provision.sh api"
assert_cmd_fails "$WEB_USER can't run any other command" sudo -u "$WEB_USER" sudo -n /opt/ddeploy/provision.sh list
assert_cmd_fails "$WEB_USER can't run a shell" sudo -u "$WEB_USER" sudo -n /bin/bash -c id
assert_cmd_fails "$WEB_USER can't pass environment through sudo" \
    sudo -u "$WEB_USER" sudo -n DDEPLOY_TRIGGER=forged /opt/ddeploy/provision.sh api info
ddeploy init-web --disable >/dev/null 2>&1
assert_file_absent /etc/sudoers.d/ddeploy-web "init-web --disable removes the sudoers rule"

step "api: cleanup"
ddeploy remove testsite --purge-db --purge-files >/dev/null 2>&1
assert_contains "$(ddeploy api sites | jq_py 'd["sites"]')" "[]" "no sites left"

echo
echo "ALL API CHECKS PASSED"
