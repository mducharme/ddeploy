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
out="$(ddeploy api site-names)"
assert_contains "$(jq_py '[s["name"] for s in d["sites"]]' <<< "$out")" '"testsite"' "site-names lists the sites"
assert_contains "$(jq_py '[s["preview"] for s in d["sites"] if s["name"] == "testsite"]' <<< "$out")" "[null]" "...and which are previews"
assert_contains "$(jq_py '[s["url"] for s in d["sites"] if s["name"] == "testsite"]' <<< "$out")" "https://testsite." "...with their address"
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
# testsite has a queue worker, restarted by every deploy: six in a row
# is more than systemd's 5 starts per 10s. Each restart must still go
# through (it used to fail the deploy with start-limit-hit).
burst_fail=0
for i in 1 2 3 4 5 6; do ddeploy deploy testsite >/dev/null 2>&1 || burst_fail=$((burst_fail + 1)); done
assert_cmd_ok "six deploys in a row: none fails on systemd's restart limit" test "$burst_fail" -eq 0
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
ddeploy api env testsite --apply --unset FEATURE_X --actor admin@example.com </dev/null >/dev/null
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

step "api: uploads — import (merge, replace), restore, download, refusals"
U=/home/deploy/persistent/testsite/web/uploads
out="$(ddeploy api uploads testsite)"
assert_contains "$(jq_py '[d["dir"] for d in d["dirs"]]' <<< "$out")" "web/uploads" "upload dirs listed"
rm -rf /tmp/up && mkdir -p /tmp/up/uploads/2024 && echo hello > /tmp/up/uploads/a.txt && echo img > /tmp/up/uploads/2024/b.jpg && touch /tmp/up/uploads/.DS_Store
(cd /tmp/up && tar -czf /tmp/up.tgz uploads)
id="$(ddeploy api run start uploads-import testsite --dir web/uploads --actor admin@example.com < /tmp/up.tgz | run_id_of)"
assert_contains "$(wait_run "$id" 120)" "succeeded" "tar.gz merged into web/uploads"
assert_file_exists "$U/2024/b.jpg" "nested file in place (the 'uploads' wrapper folder unwrapped)"
assert_file_absent "$U/.DS_Store" "junk skipped"
assert_contains "$(stat -c '%U:%G %a' "$U/a.txt")" "www-testsite:www-data 640" "files owned by the site, readable by nginx"
assert_contains "$(stat -c '%a' "$U/2024")" "2750" "folders setgid, like the persistent store's"
assert_contains "$(curl_site testsite.staging.ddeploy.test/uploads/a.txt 2>/dev/null || curl -sk --resolve testsite.staging.ddeploy.test:443:127.0.0.1 https://testsite.staging.ddeploy.test/uploads/a.txt)" "hello" "served by nginx"
python3 -c "import zipfile; z=zipfile.ZipFile('/tmp/new.zip','w'); z.writestr('new.txt','new'); z.close()"
id="$(ddeploy api run start uploads-import testsite --dir web/uploads --mode replace --actor admin@example.com < /tmp/new.zip | run_id_of)"
assert_contains "$(wait_run "$id" 120)" "succeeded" "zip replaced web/uploads"
assert_file_exists "$U/new.txt"
assert_file_absent "$U/a.txt" "replace removed what wasn't in the archive"
snap="$(ddeploy api uploads testsite | jq_py '[s["id"] for s in d["snapshots"] if s["reason"] == "pre-import"][0]')"
id="$(ddeploy api run start uploads-restore testsite --snapshot "$snap" --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 120)" "succeeded" "restored from the pre-import snapshot"
assert_file_exists "$U/a.txt" "the replaced files are back"
assert_file_absent "$U/new.txt" "and the replace is undone"
assert_contains "$(ddeploy api uploads download testsite --dir web/uploads | tar -tzf -)" "./2024/b.jpg" "download streams a .tar.gz of the folder"
python3 -c "import tarfile; t=tarfile.open('/tmp/evil.tar','w'); ti=tarfile.TarInfo('x'); ti.type=tarfile.SYMTYPE; ti.linkname='/etc'; t.addfile(ti); t.close()"
id="$(ddeploy api run start uploads-import testsite --dir web/uploads --actor admin@example.com < /tmp/evil.tar | run_id_of)"
assert_contains "$(wait_run "$id" 120)" "failed" "an archive with a symlink is refused"
assert_contains "$(ddeploy api run show "$id" | jq_py 'd["events"][-1]["error"]')" "nothing was changed" "...before anything changed"
assert_contains "$(find /var/lib/ddeploy/imports -type f | wc -l)" "0" "and its spool file is gone"
out="$(ddeploy api run start uploads-import testsite --dir ../../etc --actor admin@example.com < /tmp/new.zip 2>/dev/null || true)"
assert_contains "$out" "isn't one of" "only the site's own upload dirs"
out="$(echo hi | ddeploy api run start uploads-import testsite --dir web/uploads --actor admin@example.com 2>/dev/null || true)"
assert_contains "$out" "isn't a .zip, .tar or .tar.gz" "non-archives refused up front"

step "api: uploads — copy from another server over SSH (rsync, rrsync-bound key)"
# The "old server" is this container's own sshd, as another account.
id oldhost >/dev/null 2>&1 || useradd -m -s /bin/bash oldhost
OLD=/home/oldhost/uploads
rm -rf "$OLD"; mkdir -p "$OLD/sub"
echo from-old > "$OLD/a.txt"; echo nested > "$OLD/sub/b.txt"
echo '#!/bin/sh' > "$OLD/run.sh"; chmod 4755 "$OLD/run.sh"
ln -sf /etc/shadow "$OLD/shadow-link"
mkfifo "$OLD/pipe"
chown -R oldhost:oldhost "$OLD"
out="$(ddeploy api fetch-key)"
pub="$(jq_py 'd["public_key"]' <<< "$out")"
assert_contains "$pub" "ssh-ed25519 " "fetch key created on first use"
assert_contains "$(stat -c '%a %U' /etc/ddeploy/fetch-key)" "600 root" "private key is root-only"
assert_contains "$(jq_py 'd["authorized_keys"]' <<< "$out")" 'command="rrsync -ro' "authorized_keys line is read-only and folder-bound"
install -d -m 700 -o oldhost -g oldhost /home/oldhost/.ssh
printf 'command="rrsync -ro %s",restrict %s\n' "$OLD" "$pub" > /home/oldhost/.ssh/authorized_keys
chown oldhost:oldhost /home/oldhost/.ssh/authorized_keys; chmod 600 /home/oldhost/.ssh/authorized_keys
rm -f /etc/ddeploy/fetch-known-hosts

SRC="oldhost@127.0.0.1:"
out="$(ddeploy api fetch-test testsite --source "$SRC" --actor admin@example.com)"
assert_contains "$(jq_py 'd["host_key"]["status"]' <<< "$out")" "unknown" "a new host's key is reported, not trusted"
assert_contains "$(jq_py 'd["files"]' <<< "$out")" "null" "...and nothing is listed before it's confirmed"
fp="$(jq_py '[f["fingerprint"] for f in d["host_key"]["fingerprints"] if f["type"] == "ED25519"][0]' <<< "$out")"
if [[ "$fp" == SHA256:* ]]; then pass "fingerprint offered for confirmation ($fp)"; else fail "no fingerprint: $out"; fi
out="$(ddeploy api run start uploads-fetch testsite --dir web/uploads --source "$SRC" --actor admin@example.com 2>/dev/null || true)"
assert_contains "$out" "isn't confirmed" "a copy can't start before the host key is confirmed"
out="$(ddeploy api fetch-test testsite --source "$SRC" --accept SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA --actor admin@example.com)"
assert_contains "$(jq_py 'd["error"]' <<< "$out")" "doesn't match" "a wrong fingerprint is refused"
out="$(ddeploy api fetch-test testsite --source "$SRC" --accept "$fp" --actor admin@example.com)"
assert_contains "$(jq_py 'd["host_key"]["status"]' <<< "$out")" "known" "confirmed fingerprint remembered"
assert_contains "$(jq_py 'd["files"]' <<< "$out")" "3" "dry run counts the regular files only (no link, no fifo)"
assert_contains "$(jq_py 'd["error"]' <<< "$out")" "null" "...without error"
assert_contains "$(ddeploy api fetch-key | jq_py '[h["host"] for h in d["known_hosts"]]')" "127.0.0.1" "remembered hosts are listed"

U=/home/deploy/persistent/testsite/web/uploads
echo keep-me > "$U/existing.txt"; chown www-testsite:www-data "$U/existing.txt"
id="$(ddeploy api run start uploads-fetch testsite --dir web/uploads --source "$SRC" --mode merge --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 180)" "succeeded" "copy from the other server"
assert_contains "$(cat "$U/a.txt" 2>/dev/null)" "from-old" "files arrived"
assert_contains "$(cat "$U/sub/b.txt" 2>/dev/null)" "nested" "...with their folders"
assert_file_exists "$U/existing.txt" "merge kept the files already there"
assert_contains "$(stat -c '%U:%G' "$U/a.txt")" "www-testsite:www-data" "copied files belong to the site"
assert_contains "$(stat -c '%a' "$U/run.sh")" "640" "no setuid or executable bit comes across"
assert_file_absent "$U/shadow-link" "symlinks are not copied"
assert_file_absent "$U/pipe" "special files are not copied"
show="$(ddeploy api run show "$id")"
assert_contains "$show" '"kind":"uploads-fetch"' "recorded as an uploads-fetch"
assert_contains "$show" "oldhost@127.0.0.1:" "...naming the source"
undo="$(grep -oE '[0-9]{8}T[0-9]{6}Z-pre-import-[a-z0-9-]+' <<< "$show" | head -n 1)"
if [[ -n "$undo" ]]; then pass "a snapshot was taken first ($undo)"; else fail "no undo snapshot in: $show"; fi

out="$(ddeploy api fetch-test testsite --source "oldhost@127.0.0.1:../../../etc" --actor admin@example.com 2>&1 || true)"
assert_contains "$out" "may not contain '..'" "'..' paths refused before connecting"
out="$(ddeploy api fetch-test testsite --source "oldhost@127.0.0.1:/etc" --actor admin@example.com)"
assert_contains "$(jq_py 'd["error"]' <<< "$out")" "/home/oldhost/uploads/etc" "with rrsync, /etc means <bound folder>/etc — never the real /etc"
out="$(ddeploy api fetch-test testsite --source "oldhost@127.0.0.1:/sub" --actor admin@example.com)"
assert_contains "$(jq_py 'd["files"]' <<< "$out")" "1" "...and /sub is the bound folder's sub/"
id nokey >/dev/null 2>&1 || useradd -m -s /bin/bash nokey
out="$(ddeploy api fetch-test testsite --source "nokey@127.0.0.1:" --actor admin@example.com)"
assert_contains "$(jq_py 'd["error"]' <<< "$out")" "refused the key" "an account without the key: explained"
out="$(ddeploy api fetch-test testsite --source "oldhost@127.0.0.1:" --port 2299 --actor admin@example.com)"
assert_contains "$(jq_py 'd["error"]' <<< "$out")" "can't reach 127.0.0.1:2299" "nothing listening: explained"

# A reinstalled server presents a different key: refused until forgotten.
ssh-keygen -q -t ed25519 -N '' -f /tmp/other-hostkey <<< y >/dev/null 2>&1
printf '127.0.0.1 %s\n' "$(cut -d' ' -f1,2 /tmp/other-hostkey.pub)" > /etc/ddeploy/fetch-known-hosts
rm -f /tmp/other-hostkey /tmp/other-hostkey.pub
out="$(ddeploy api fetch-test testsite --source "$SRC" --actor admin@example.com)"
assert_contains "$(jq_py 'd["host_key"]["status"]' <<< "$out")" "changed" "a changed host key is refused"
out="$(ddeploy api run start uploads-fetch testsite --dir web/uploads --source "$SRC" --actor admin@example.com 2>/dev/null || true)"
assert_contains "$out" "isn't confirmed (changed)" "...and no copy starts"
ddeploy api fetch-key forget --host 127.0.0.1 --actor admin@example.com >/dev/null
out="$(ddeploy api fetch-test testsite --source "$SRC" --actor admin@example.com)"
assert_contains "$(jq_py 'd["host_key"]["status"]' <<< "$out")" "unknown" "forgotten: asks for confirmation again"
assert_contains "$(tail -n 3 /var/log/ddeploy/server-config.log)" "forgot 127.0.0.1" "host-key decisions are logged"
rm -f "$U/a.txt" "$U/run.sh" "$U/existing.txt"; rm -rf "$U/sub"

step "api: config files (persistent_files, charcoal's config.local.json) — read, edit, restore"
ddeploy override testsite persistent_files="config/app.json wp-config.php" >/dev/null 2>&1
id="$(ddeploy api run start deploy testsite --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 300)" "succeeded" "deploy links the declared persistent files"
P=/home/deploy/persistent/testsite
printf '{"name":"x"}\n' > "$P/config/app.json"; printf '<?php\ndefine("A", 1);\n' > "$P/wp-config.php"
chown www-testsite:www-data "$P/config/app.json" "$P/wp-config.php"; chmod 600 "$P/config/app.json" "$P/wp-config.php"
out="$(ddeploy api files testsite)"
assert_contains "$(jq_py '[f["path"] + ":" + f["format"] for f in d["files"]]' <<< "$out")" '"config/app.json:json", "wp-config.php:php"' "lists the config files with their format"
assert_not_contains "$(jq_py '[f["path"] for f in d["files"]]' <<< "$out")" '".env"' "...not .env (the Environment tab edits it)"
r="$(ddeploy api files testsite --read config/app.json)"
sha="$(jq_py 'd["sha256"]' <<< "$r")"
assert_contains "$(jq_py 'd["content"]' <<< "$r")" '{"name":"x"}' "reads the content"
assert_contains "$(jq_py 'repr(d["content"][-1:])' <<< "$r")" "'\\n'" "...exactly, final newline included"
out="$(printf '{"name": }' | ddeploy api files testsite --write config/app.json --actor admin@example.com 2>/dev/null || true)"
assert_contains "$out" "invalid JSON" "invalid JSON refused, with why"
out="$(printf '<?php define("A" 1);' | ddeploy api files testsite --write wp-config.php --actor admin@example.com 2>/dev/null || true)"
assert_contains "$out" "syntax error" "a PHP syntax error refused (php -l, nothing run)"
printf '{"name":"y"}\n' | ddeploy api files testsite --write config/app.json --expect-sha "$sha" --actor admin@example.com >/dev/null
assert_contains "$(cat "$P/config/app.json")" '"y"' "saved"
assert_contains "$(stat -c '%U:%G %a' "$P/config/app.json")" "www-testsite:www-data 600" "...keeping its owner and mode"
out="$(printf '{"name":"z"}\n' | ddeploy api files testsite --write config/app.json --expect-sha "$sha" --actor admin@example.com 2>/dev/null || true)"
assert_contains "$out" "changed since you opened it" "a stale edit is refused"
v="$(ddeploy api files testsite --read config/app.json | jq_py 'd["versions"][0]["id"]')"
assert_contains "$(stat -c '%U %a' "/var/lib/ddeploy/file-versions/testsite/config%app.json/$v")" "root 600" "the previous version is kept, root-only"
ddeploy api files testsite --restore config/app.json --version "$v" --actor admin@example.com >/dev/null
assert_contains "$(cat "$P/config/app.json")" '"x"' "restored"
assert_contains "$(tail -n 1 /var/lib/ddeploy/events/testsite.jsonl)" '"kind":"file-change"' "changes land in the site's history"
printf '{"n":1}\n' | ddeploy api files testsite --write config/app.json --actor admin@example.com >/dev/null
printf '{"n":2}\n' | ddeploy api files testsite --write config/app.json --actor admin@example.com >/dev/null
assert_contains "$(ddeploy api files testsite --read config/app.json | jq_py 'd["versions"][0]["id"] != d["versions"][1]["id"]')" "true" "two saves in a row keep two versions"
assert_contains "$(cat "/var/lib/ddeploy/file-versions/testsite/config%app.json/$(ddeploy api files testsite --read config/app.json | jq_py 'd["versions"][0]["id"]')")" '"n":1' "...the newest being what the last save replaced"
out="$(ddeploy api files testsite --read ../../../etc/shadow 2>/dev/null || true)"
assert_contains "$out" "isn't one of" "only the listed files"
mv "$P/wp-config.php" /tmp/wpc.bak; ln -s /etc/shadow "$P/wp-config.php"
out="$(ddeploy api files testsite --read wp-config.php 2>/dev/null || true)"
assert_not_contains "$out" "root:" "a symlink to a root-only file isn't read as root"
printf '<?php\n' | ddeploy api files testsite --write wp-config.php --actor admin@example.com >/dev/null 2>&1 || true
assert_contains "$(head -c 5 /etc/shadow)" "root:" "...nor written through"
rm -f "$P/wp-config.php"; mv /tmp/wpc.bak "$P/wp-config.php"
ddeploy override testsite --unset persistent_files >/dev/null 2>&1 || true

step "api: backups — a site with nothing in object storage yet"
# Earlier steps already backed testsite up: set its prefix aside, as if new.
remote="$(cd /opt/ddeploy && bash -c 'source lib/common.sh; load_conf >/dev/null 2>&1; source lib/backup.sh; backup_remote_spec')"
export RCLONE_CONFIG=/etc/ddeploy/rclone-backup.conf   # lib/common.sh
rclone moveto "$remote/testsite" "$remote/zz-aside-testsite" >/dev/null 2>&1 || true
if out="$(ddeploy api backups testsite)"; then pass "api backups works with no backups yet"; else fail "api backups failed with no backups: $out"; fi
assert_contains "$(jq_py 'len(d["database"]["dumps"])' <<< "$out")" "0" "...no dumps"
assert_contains "$(jq_py 'd["error"]' <<< "$out")" "null" "...and no error"
assert_contains "$(jq_py 'len(d["uploads"]["versions"])' <<< "$out")" "0" "...no versions"
upl_check() { ddeploy api doctor testsite | jq_py '[c["status"] + " " + c["detail"] for s in d["sites"] for c in s["checks"] if c["check"] == "uploads backup"][0]'; }
P=/home/deploy/persistent/testsite
mkdir -p /tmp/upl-aside && rm -rf /tmp/upl-aside/*
for d in web/uploads private-uploads; do
    [[ -d "$P/$d" ]] && mkdir -p "/tmp/upl-aside/$(dirname "$d")" && mv "$P/$d" "/tmp/upl-aside/$d"
    install -d -o www-testsite -g www-data -m 2750 "$P/$d"
done
assert_contains "$(upl_check)" "ok upload folders are empty" "doctor: empty upload folders have nothing to back up (ok)"
echo x > "$P/web/uploads/new.txt"
assert_contains "$(upl_check)" "warn 'web/uploads' has files but none in" "doctor: files locally, none in the bucket (warn)"
for d in web/uploads private-uploads; do
    rm -rf "${P:?}/$d"
    [[ -d "/tmp/upl-aside/$d" ]] && mv "/tmp/upl-aside/$d" "$P/$d"
done
rclone moveto "$remote/zz-aside-testsite" "$remote/testsite" >/dev/null 2>&1 || true
assert_contains "$(ddeploy api backups testsite | jq_py 'len(d["database"]["dumps"]) > 0')" "true" "backups back in place"

step "api: backups — an endpoint that already names the bucket is explained, not \"no backups\""
creds="$(sed -n 's/^BACKUP_CREDENTIALS="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/ddeploy/provisioner.conf)"
bucket="$(sed -n 's/^BACKUP_BUCKET="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/ddeploy/provisioner.conf)"
cp "$creds" /tmp/creds.before
sed -i "s#^BACKUP_ENDPOINT=.*#BACKUP_ENDPOINT=\"https://$bucket.tor1.digitaloceanspaces.com\"#" "$creds"
out="$(ddeploy api backups testsite)"
assert_contains "$(jq_py 'd["error"]' <<< "$out")" "BACKUP_ENDPOINT includes the bucket name" "api backups explains the endpoint"
assert_contains "$(jq_py 'd["error"]' <<< "$out")" "https://tor1.digitaloceanspaces.com" "...with the endpoint to use"
out="$(ddeploy doctor --no-notify 2>&1 || true)"
assert_contains "$out" "BACKUP_ENDPOINT includes the bucket name" "doctor fails on it"
cp /tmp/creds.before "$creds"
assert_contains "$(ddeploy api backups testsite | jq_py 'd["error"]')" "null" "fine again with the region endpoint"

step "api: backups — BACKUP_BUCKET in the credentials file (next to the endpoint)"
cp /etc/ddeploy/provisioner.conf /tmp/conf.bucket-before
cp "$creds" /tmp/creds.bucket-before
printf 'BACKUP_BUCKET="%s"\n' "$bucket" >> "$creds"
sed -i 's/^BACKUP_BUCKET=.*/BACKUP_BUCKET=""/' /etc/ddeploy/provisioner.conf
out="$(ddeploy api backups testsite)"
assert_contains "$(jq_py 'd["bucket"]' <<< "$out")" "$bucket" "bucket read from the credentials file"
assert_contains "$(jq_py 'd["error"]' <<< "$out")" "null" "...and listing works"
assert_contains "$(ddeploy api config | jq_py 'd["readonly"]["BACKUP_BUCKET"]')" "$bucket" "server settings show it too"
sed -i "s/^BACKUP_BUCKET=.*/BACKUP_BUCKET=\"some-other-bucket\"/" /etc/ddeploy/provisioner.conf
assert_contains "$(ddeploy api backups testsite | jq_py 'd["bucket"]')" "$bucket" "the credentials file wins over provisioner.conf"
assert_contains "$(ddeploy doctor --no-notify 2>&1 || true)" "ignored) — remove the one in provisioner.conf" "doctor warns when the two differ"
cp /tmp/conf.bucket-before /etc/ddeploy/provisioner.conf
cp /tmp/creds.bucket-before "$creds"
assert_contains "$(ddeploy api backups testsite | jq_py 'd["bucket"]')" "$bucket" "provisioner.conf alone still works (older setups)"

step "api: backups — a key limited to the bucket (no bucket creation) can back up"
cp "$creds" /tmp/creds.limited-before
sed -i 's/^BACKUP_ACCESS_KEY=.*/BACKUP_ACCESS_KEY="limitedkey"/; s/^BACKUP_SECRET_KEY=.*/BACKUP_SECRET_KEY="limitedsecret123"/' "$creds"
id="$(ddeploy api run start backup-database testsite --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 180)" "succeeded" "database backup with a bucket-limited key"
assert_not_contains "$(ddeploy api run log "$id")" "AccessDenied" "...no AccessDenied on upload"
assert_contains "$(ddeploy api backups testsite | jq_py 'd["error"]')" "null" "...and it lists"
sed -i 's/^BACKUP_SECRET_KEY=.*/BACKUP_SECRET_KEY="wrong"/' "$creds"
id="$(ddeploy api run start backup-database testsite --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 180)" "failed" "a backup with a wrong key fails"
err="$(ddeploy api run show "$id" | jq_py '[e.get("error") for e in d["events"] if e["phase"] == "failed"][0]')"
assert_contains "$err" "upload to $bucket failed:" "...and its error says what failed"
assert_contains "$err" "Forbidden" "...with rclone's reason, not just 'failed'"
cp /tmp/creds.limited-before "$creds"

step "api: backups — run now, versions, restore, keep/delete, download"
U=/home/deploy/persistent/testsite/web/uploads
echo v1 > "$U/doc.txt"; echo keep > "$U/keep.txt"; chown www-testsite:www-data "$U/doc.txt" "$U/keep.txt"
id="$(ddeploy api run start backup-uploads testsite --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 180)" "succeeded" "uploads backed up on demand"
sleep 1
echo v2 > "$U/doc.txt"; rm "$U/keep.txt"
id="$(ddeploy api run start backup-uploads testsite --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 180)" "succeeded" "second uploads backup"
out="$(ddeploy api backups testsite)"
version="$(jq_py 'd["uploads"]["versions"][0]["id"]' <<< "$out")"
if [[ "$version" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then pass "the second backup kept what it overwrote/deleted as version $version"; else fail "no uploads version: $out"; fi
assert_contains "$(jq_py 'd["uploads"]["last_run"]["trigger"]' <<< "$out")" "web (admin@example.com)" "last uploads backup attributed"
id="$(ddeploy api run start backup-restore-uploads testsite --dir web/uploads --version "$version" --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 180)" "succeeded" "restore from a version"
assert_file_exists "$U/keep.txt" "a file deleted since the previous backup is back"
assert_contains "$(cat "$U/doc.txt")" "v1" "an overwritten file is back to its previous content"
assert_contains "$(stat -c '%U:%G' "$U/keep.txt")" "www-testsite:www-data" "restored files belong to the site, not root"
echo junk > "$U/junk.txt"
id="$(ddeploy api run start backup-restore-uploads testsite --dir web/uploads --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 180)" "succeeded" "restore from the mirror"
assert_file_absent "$U/junk.txt" "the mirror restore replaced the folder"
assert_contains "$(cat "$U/doc.txt")" "v2" "...with the backed-up content"
DBA=(mysql --defaults-extra-file=/etc/ddeploy/db-admin.cnf -h dbhost testsite)
"${DBA[@]}" -e "CREATE TABLE IF NOT EXISTS backup_probe (id int); INSERT INTO backup_probe VALUES (1);"
id="$(ddeploy api run start backup-database testsite --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 180)" "succeeded" "database backed up on demand"
dump="$(ddeploy api backups testsite | jq_py 'd["database"]["dumps"][0]["file"]')"
assert_contains "$dump" ".sql.gz" "the new dump is listed first ($dump)"
"${DBA[@]}" -e "DROP TABLE backup_probe; CREATE TABLE after_backup (id int);"
id="$(ddeploy api run start backup-restore-db testsite --file "$dump" --actor admin@example.com | run_id_of)"
assert_contains "$(wait_run "$id" 180)" "succeeded" "database restored from the backup"
tables="$("${DBA[@]}" -N -e 'SHOW TABLES')"
assert_contains "$tables" "backup_probe" "the backed-up table is back"
assert_not_contains "$tables" "after_backup" "and tables created since are gone"
ddeploy api backups keep testsite --file "$dump" --actor admin@example.com >/dev/null
assert_contains "$(ddeploy api backups testsite | jq_py 'd["database"]["dumps"][0]["kept"]')" "true" "kept dump is marked kept"
assert_contains "$(ddeploy api backups download testsite --file "$dump" | gunzip)" "CREATE TABLE \`backup_probe\`" "a kept dump downloads"
ddeploy api backups delete testsite --file "$dump" --actor admin@example.com >/dev/null
assert_not_contains "$(ddeploy api backups testsite | jq_py '[x["file"] for x in d["database"]["dumps"]]')" "$dump" "deleted dump is gone"
out="$(ddeploy api backups delete testsite --file ../../etc/passwd --actor admin@example.com 2>/dev/null || true)"
assert_contains "$out" "invalid backup name" "path-like dump names refused"
assert_contains "$(ddeploy api sites | jq_py '[s["last_backups"]["database"]["phase"] for s in d["sites"] if s["name"] == "testsite"]')" "succeeded" "the site list shows the last backup"

step "api: server settings (provisioner.conf, sourced by root)"
cp /etc/ddeploy/provisioner.conf /tmp/provisioner.conf.before
out="$(printf 'FPM_MAX_CHILDREN=8\nBACKUP_SCHEDULE=42 * * * *\nNOTIFY_EVENTS=deploy-failure\n' | ddeploy api config set --actor root@example.com)"
assert_contains "$(jq_py '[s["value"] for s in d["settings"] if s["key"] == "FPM_MAX_CHILDREN"]' <<< "$out")" '"8"' "setting saved"
assert_contains "$(cat /etc/cron.d/ddeploy-backup-uploads)" "42 * * * *" "a changed schedule rewrites the cron job"
assert_contains "$(cat /etc/cron.d/ddeploy-backup-uploads)" "root DDEPLOY_TRIGGER=schedule " "scheduled runs are attributed to the schedule, not 'manual'"
assert_contains "$(grep -c '^FPM_MAX_CHILDREN=' /etc/ddeploy/provisioner.conf)" "1" "one line per key"
assert_contains "$(tail -n 1 /var/log/ddeploy/server-config.log)" "web (root@example.com)" "change logged with who made it"
# The newest backup is the file as it was before this change (earlier runs may have left others).
newest_bak="$(find /etc/ddeploy -maxdepth 1 -name 'provisioner.conf.bak-*' | sort | tail -n 1)"
if [[ -n "$newest_bak" ]] && cmp -s "$newest_bak" /tmp/provisioner.conf.before; then pass "the previous file was backed up"; else fail "no backup matching the previous provisioner.conf (${newest_bak:-none})"; fi
# shellcheck disable=SC2016  # literal injection attempts, on purpose
for bad in 'BASE_DOMAIN=evil.test' 'FPM_MAX_CHILDREN=$(touch /tmp/pwned)' 'DEFAULT_PHP=8.3`touch /tmp/pwned`' 'BACKUP_SCHEDULE=* * * * * root touch /tmp/pwned'; do
    out="$(echo "$bad" | ddeploy api config set --actor root@example.com 2>/dev/null || true)"
    assert_contains "$out" '"code":"bad_request"' "refused: ${bad%%=*}=…"
done
ddeploy list >/dev/null 2>&1 || true
assert_file_absent /tmp/pwned "nothing injected ran (the file is sourced by every command)"
assert_cmd_ok "provisioner.conf still loads" bash -c 'source /opt/ddeploy/lib/common.sh && load_conf'
cat /tmp/provisioner.conf.before > /etc/ddeploy/provisioner.conf
printf 'BACKUP_SCHEDULE=17 * * * *\n' | ddeploy api config set --actor root@example.com >/dev/null

step "init-web: the web UI's sudoers rule is api-only"
ddeploy init-web >/dev/null 2>&1
assert_file_exists /etc/sudoers.d/ddeploy-web
assert_file_exists /etc/nginx/sites-enabled/ddeploy-web.conf
assert_cmd_ok "nginx accepts the web UI vhost" nginx -t
assert_cmd_ok "sudoers rule passes visudo" visudo -cqf /etc/sudoers.d/ddeploy-web
printf 'WEB_UPLOAD_MAX_MB=777\n' | ddeploy api config set --actor root@example.com >/dev/null
assert_contains "$(cat /etc/nginx/sites-available/ddeploy-web.conf)" "client_max_body_size 777m" "a changed upload limit re-renders the web UI vhost"
assert_cmd_ok "nginx still accepts it" nginx -t
printf 'WEB_UPLOAD_MAX_MB=10240\n' | ddeploy api config set --actor root@example.com >/dev/null
out="$(sudo -u "$WEB_USER" sudo -n /opt/ddeploy/provision.sh api info)"
assert_contains "$out" '"api_version":1' "$WEB_USER can run provision.sh api"
assert_cmd_fails "$WEB_USER can't run any other command" sudo -u "$WEB_USER" sudo -n /opt/ddeploy/provision.sh list
assert_cmd_fails "$WEB_USER can't run a shell" sudo -u "$WEB_USER" sudo -n /bin/bash -c id
assert_cmd_fails "$WEB_USER can't pass environment through sudo" \
    sudo -u "$WEB_USER" sudo -n DDEPLOY_TRIGGER=forged /opt/ddeploy/provision.sh api info
ddeploy init-web --disable >/dev/null 2>&1
assert_file_absent /etc/sudoers.d/ddeploy-web "init-web --disable removes the sudoers rule"

step "read index: api sites/site/list come from it, and stay correct"
INDEX=/var/lib/ddeploy/index
ddeploy api sites > /tmp/sites1.json
assert_file_exists "$INDEX/testsite.summary" "api sites built testsite's index row"
assert_cmd_ok "the index is root-only" test "$(stat -c %a "$INDEX")" = 700
fp_mtime="$(stat -c %Y.%N "$INDEX/testsite.fp")"
sleep 1
ddeploy api sites > /tmp/sites2.json
assert_cmd_ok "a second api sites returns the same JSON" cmp -s /tmp/sites1.json /tmp/sites2.json
assert_cmd_ok "...without rebuilding the row (fingerprint unchanged)" test "$fp_mtime" = "$(stat -c %Y.%N "$INDEX/testsite.fp")"
ddeploy override testsite client_max_body_size=77M >/dev/null
assert_contains "$(ddeploy api site testsite | jq_py 'd["config"]["settings"]["client_max_body_size"]')" "77M" \
    "an override shows in api site immediately (its file is in the fingerprint)"
assert_contains "$(ddeploy list)" "testsite" "list reads the same rows"
ddeploy override testsite --unset client_max_body_size >/dev/null

step "event feed: seq, --after, CLI changes, concurrent writers"
feed="$(ddeploy api events --limit 1)"
seq0="$(jq_py 'd["seq"]' <<< "$feed")"
assert_cmd_ok "api events reports the newest seq" test "$seq0" -gt 0
ddeploy override testsite fpm_max_children=7 >/dev/null
newer="$(ddeploy api events --after "$seq0")"
assert_contains "$(jq_py '[e["kind"] for e in d["events"]]' <<< "$newer")" '"settings-change"' \
    "a CLI override is in the feed (settings-change)"
assert_contains "$(jq_py 'd["events"][-1]["subject"]' <<< "$newer")" "fpm_max_children=7" "...with what changed"
assert_contains "$(jq_py 'd["truncated"]' <<< "$newer")" "false" "...and the feed wasn't truncated"
seq1="$(jq_py 'd["seq"]' <<< "$newer")"
ddeploy api settings testsite --unset fpm_max_children --actor admin@example.com >/dev/null
assert_contains "$(ddeploy api events --after "$seq1" | jq_py 'len([e for e in d["events"] if e["kind"] == "settings-change"])')" "1" \
    "a web settings change is recorded once (not again by the override it runs)"
paging="$(ddeploy api events --after 0 --limit 2 | jq_py '[e["seq"] for e in d["events"]]')"
assert_contains "$paging" "[1, 2]" "--after pages forward from the cursor (oldest first)"
assert_cmd_fails "--after with --site is refused" ddeploy api events --site testsite --after 1

# 20 writers at once, with trimming forced on every write: the lock must
# keep every line, in both files, with unique consecutive seqs.
before_lines="$(wc -l < /var/lib/ddeploy/events/_fleet.jsonl)"
before_site="$(grep -c '"subject":"concurrent ' /var/lib/ddeploy/events/testsite.jsonl || true)"
before_seq="$(ddeploy api events --limit 1 | jq_py 'd["seq"]')"
EVENTS_MAX_BYTES=1 EVENTS_KEEP_LINES=100000 bash -c '
    cd /opt/ddeploy
    while read -r f; do source "lib/$f"; done < <(sed -n "s|^source \"\$LIB_DIR/\(.*\)\"\$|\1|p" provision.sh)
    load_conf
    for i in $(seq 1 20); do event_record testsite deploy started "subject=concurrent $i" & done
    wait'
after_seq="$(ddeploy api events --limit 1 | jq_py 'd["seq"]')"
assert_cmd_ok "20 concurrent events: 20 new seqs" test "$after_seq" -eq "$((before_seq + 20))"
assert_cmd_ok "...all 20 lines kept through the trims" test "$(wc -l < /var/lib/ddeploy/events/_fleet.jsonl)" -eq "$((before_lines + 20))"
assert_contains "$(ddeploy api events --after "$before_seq" --limit 100 | jq_py 'sorted(e["seq"] for e in d["events"]) == list(range('"$before_seq"' + 1, '"$after_seq"' + 1))')" "true" \
    "...each seq exactly once, none skipped"
assert_cmd_ok "...and in the site's own file too" \
    test "$(grep -c '"subject":"concurrent ' /var/lib/ddeploy/events/testsite.jsonl)" -eq "$((before_site + 20))"

step "doctor snapshot: stored, served without checking, health on sites"
ddeploy api doctor >/dev/null
assert_file_exists "$INDEX/doctor/sites/testsite.json" "api doctor stores the site's result"
snap="$(ddeploy api doctor --snapshot)"
assert_contains "$(jq_py '[s["name"] for s in d["sites"]]' <<< "$snap")" '"testsite"' "api doctor --snapshot serves it"
assert_contains "$(jq_py 'd["sites"][0]["checked_at"] is not None and d["server"]["checked_at"] is not None' <<< "$snap")" "true" \
    "...with when each part was checked"
health="$(ddeploy api sites | jq_py '[d["sites"][0].get("health"), d["sites"][0].get("health_checked_at") is not None]')"
assert_contains "$health" '"' "api sites carries each site's last health"
assert_contains "$health" "true" "...and when it was checked"
ddeploy doctor --snapshot >/dev/null 2>&1
assert_cmd_ok "doctor --snapshot (the cron job) refreshes it" test "$INDEX/doctor/server.json" -nt /tmp/sites2.json
assert_file_exists /etc/cron.d/ddeploy-doctor "init installed the doctor snapshot cron job"
assert_contains "$(cat /etc/cron.d/ddeploy-doctor)" "doctor --snapshot" "...running doctor --snapshot"

step "api: cleanup"
ddeploy remove testsite --purge-db --purge-files >/dev/null 2>&1
assert_contains "$(ddeploy api sites | jq_py 'd["sites"]')" "[]" "no sites left"
assert_file_absent "$INDEX/testsite.summary" "remove dropped the site's index row"
assert_contains "$(ddeploy api events --limit 1 | jq_py 'd["events"][-1]["kind"]')" "remove" "remove is in the event feed"

echo
echo "ALL API CHECKS PASSED"
