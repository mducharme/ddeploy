#!/usr/bin/env bash
# Fast, root-free unit tests for the pure-bash helpers behind the `api`
# subcommand: JSON emitters (lib/json.sh), the event log (lib/events.sh)
# and the api argument validators (lib/cmd_api.sh). Everything that needs
# root, systemd or a real site is in docker/test (steps/04-api.sh).
#
# Usage: tests/unit.sh     (needs python3, for an independent JSON parser)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=lib/common.sh
source lib/common.sh
# shellcheck source=lib/json.sh
source lib/json.sh
# shellcheck source=lib/events.sh
source lib/events.sh
# shellcheck source=lib/config.sh
source lib/config.sh
# shellcheck source=lib/cmd_db.sh
source lib/cmd_db.sh
# shellcheck source=lib/cmd_api.sh
source lib/cmd_api.sh
# shellcheck source=lib/cmd_api_config.sh
source lib/cmd_api_config.sh
# shellcheck source=lib/backup.sh
source lib/backup.sh
# shellcheck source=lib/cmd_fetch.sh
source lib/cmd_fetch.sh
# shellcheck source=lib/cmd_api_files.sh
source lib/cmd_api_files.sh
notify_trigger() { printf 'manual (tester)'; }

PASSES=0
FAILS=0
ok()   { PASSES=$((PASSES + 1)); printf '  \033[32m[pass]\033[0m %s\n' "$*"; }
bad()  { FAILS=$((FAILS + 1)); printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }

# $1 description, $2 JSON text, $3 python expression over `d` that must be True.
assert_json() {
    local desc="$1" json="$2" expr="$3"
    if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if eval(sys.argv[2]) else 1)' "$json" "$expr" 2>/dev/null; then
        ok "$desc"
    else
        bad "$desc — got: $json"
    fi
}

assert_eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
assert_ok()   { local d="$1"; shift; if ( "$@" ) >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
assert_fail() { local d="$1"; shift; if ( "$@" ) >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

echo "json.sh"
assert_json "plain string" "$(json_str hello)" 'd == "hello"'
# shellcheck disable=SC1003  # a literal trailing backslash, on purpose
assert_json "quotes and backslashes" "$(json_str 'a "b" \c\')" 'd == "a \"b\" \\c\\"'
assert_json "newline, tab, CR" "$(json_str $'l1\nl2\tt\rr')" 'd == "l1\nl2\tt\rr"'
assert_json "other control bytes dropped" "$(json_str $'a\x1b[31mb\x07c')" 'd == "a[31mbc"'
assert_json "unicode kept" "$(json_str 'café ✓')" 'd == "café ✓"'
assert_json "empty string" "$(json_str '')" 'd == ""'
assert_json "number" "$(json_num 42)" 'd == 42'
assert_json "non-number is null" "$(json_num 4x)" 'd is None'
assert_json "bool true" "$(json_bool yes)" 'd is True'
assert_json "bool false" "$(json_bool false)" 'd is False'
assert_json "bool empty is null" "$(json_bool '')" 'd is None'
assert_json "str_or_null empty" "$(json_str_or_null '')" 'd is None'
assert_json "string array" "$(json_str_array a 'b c' '"q"')" 'd == ["a", "b c", "\"q\""]'
assert_json "empty array" "$(json_str_array)" 'd == []'
assert_json "lines to array" "$(printf '{"a":1}\n\n{"b":2}\n' | json_lines_to_array)" 'd == [{"a": 1}, {"b": 2}]'
tmpf="$(mktemp)"
printf 'line one\n\ttabbed "quoted" \\ back\n\x1b[1mbold\x1b[0m\n' > "$tmpf"
assert_json "file as string" "$(json_str_file "$tmpf")" 'd == "line one\n\ttabbed \"quoted\" \\ back\n[1mbold[0m\n"'
: > "$tmpf"
assert_json "empty file" "$(json_str_file "$tmpf")" 'd == ""'
rm -f "$tmpf"

echo "events.sh"
EVENTS_DIR="$(mktemp -d)/events"
DDEPLOY_RUN_ID="20261002T120000Z-abcdef"
assert_ok "new_run_id matches RUN_ID_RE" bash -c "[[ '$(new_run_id)' =~ $RUN_ID_RE ]]"
assert_ok "valid run id accepted" validate_run_id 20261002T120000Z-abcdef
assert_fail "path traversal run id refused" validate_run_id '../../etc/passwd'
assert_fail "uppercase hex refused" validate_run_id 20261002T120000Z-ABCDEF
event_record mysite deploy started
event_record mysite deploy succeeded "to_sha=abc123" "duration_s=12" "subject=fix \"quotes\"" "empty=" "Bad-Key=x"
mapfile -t lines < "$EVENTS_DIR/mysite.jsonl"
assert_json "started event" "${lines[0]}" 'd["site"] == "mysite" and d["kind"] == "deploy" and d["phase"] == "started" and d["run_id"] == "20261002T120000Z-abcdef" and d["trigger"] == "manual (tester)"'
assert_json "final event extras" "${lines[1]}" 'd["to_sha"] == "abc123" and d["duration_s"] == 12 and d["subject"] == "fix \"quotes\"" and "empty" not in d and "Bad-Key" not in d'
assert_ok "events start with {\"ts\": (sortable)" bash -c "grep -c '^{\"ts\":\"' '$EVENTS_DIR/mysite.jsonl' | grep -qx 2"
assert_json "events carry a fleet-wide seq" "${lines[1]}" 'd["seq"] == 2'
assert_eq "the fleet tail has the same lines" "$(cat "$EVENTS_DIR/mysite.jsonl")" "$(cat "$EVENTS_DIR/_fleet.jsonl")"
event_record othersite provision started
assert_eq "seq keeps growing across sites" 3 "$(events_last_seq)"
assert_eq "events_site_files lists sites, never _fleet" "mysite.jsonl othersite.jsonl" "$(events_site_files | xargs -n1 basename | sort | tr '\n' ' ' | sed 's/ $//')"

# A server upgraded from before the fleet tail: _fleet.jsonl is built
# from the per-site files, by time, and numbered in that order.
old_events="$(mktemp -d)"
printf '{"ts":"2026-10-01T10:00:00Z","site":"a","kind":"deploy","phase":"started"}\n{"ts":"2026-10-01T12:00:00Z","site":"a","kind":"deploy","phase":"succeeded"}\n' > "$old_events/a.jsonl"
printf '{"ts":"2026-10-01T11:00:00Z","site":"b","kind":"deploy","phase":"started"}\n' > "$old_events/b.jsonl"
(EVENTS_DIR="$old_events"; events_fleet_init)
assert_eq "fleet tail built from older per-site files, merged by time" "1:a 2:b 3:a" \
    "$(python3 -c 'import json,sys; print(" ".join("%d:%s" % (d["seq"], d["site"]) for d in map(json.loads, open(sys.argv[1]))))' "$old_events/_fleet.jsonl")"
assert_eq "...and the counter continues from there" 3 "$(EVENTS_DIR="$old_events"; events_last_seq)"
(EVENTS_DIR="$old_events"; event_record b deploy succeeded)
assert_json "the next event is seq 4" "$(tail -n 1 "$old_events/_fleet.jsonl")" 'd["seq"] == 4 and d["site"] == "b"'
rm -rf "$old_events"
DDEPLOY_EVENT_ATTRS="$(mktemp)"
event_attr kind rollback
event_attr to_sha one
event_attr to_sha $'two\nlines'
assert_ok "event_attr_get last value wins, newlines flattened" bash -c "[[ \"\$(source lib/events.sh 2>/dev/null; event_attr_get '$DDEPLOY_EVENT_ATTRS' to_sha)\" == 'two lines' ]]"
assert_ok "event_attr_get default" bash -c "[[ \"\$(source lib/events.sh 2>/dev/null; event_attr_get '$DDEPLOY_EVENT_ATTRS' phase succeeded)\" == succeeded ]]"
rm -f "$DDEPLOY_EVENT_ATTRS"
unset DDEPLOY_EVENT_ATTRS
assert_ok "event_attr outside a run is a no-op" event_attr kind x

echo "events trimming"
trimf="$(mktemp)"
for i in $(seq 1 50); do printf '{"ts":"2026-10-02T00:00:%02dZ","n":%d}\n' "$((i % 60))" "$i" >> "$trimf"; done
EVENTS_MAX_BYTES=100 EVENTS_KEEP_LINES=10 events_trim "$trimf"
assert_ok "trimmed to the newest lines" bash -c "[[ \$(wc -l < '$trimf') -eq 10 && \$(tail -n 1 '$trimf') == *'\"n\":50}' ]]"
EVENTS_MAX_BYTES=100000000 events_trim "$trimf"
assert_ok "small files left alone" bash -c "[[ \$(wc -l < '$trimf') -eq 10 ]]"
rm -f "$trimf"
assert_ok "event_record refuses a path-like site name" bash -c "source lib/common.sh; source lib/json.sh; source lib/events.sh; notify_trigger() { :; }; EVENTS_DIR=\$(mktemp -d); event_record '../x' deploy started; [[ -z \$(ls -A \$EVENTS_DIR) && ! -e \$EVENTS_DIR/../x.jsonl ]]"

echo "api log names"
LOG_DIR=/var/log/ddeploy
for pair in "testsite:/var/log/ddeploy/testsite.log" "webhook:/var/log/ddeploy/webhook.log" \
            "testsite.access:/var/log/nginx/testsite.access.log" "testsite.error:/var/log/nginx/testsite.error.log" \
            "nginx_access:/var/log/nginx/access.log" "nginx_error:/var/log/nginx/error.log" \
            "php8.3_fpm:/var/log/php8.3-fpm.log"; do
    assert_ok "log ${pair%%:*} -> ${pair#*:}" bash -c "source lib/common.sh; source lib/json.sh; source lib/cmd_api.sh; LOG_DIR=/var/log/ddeploy; [[ \$(api_log_path '${pair%%:*}') == '${pair#*:}' ]]"
done
for bad in '../etc/passwd' 'testsite.access.log' 'nginx_../x' 'php8.3_fpm/../../etc' 'Testsite' 'site.debug'; do
    assert_fail "log name '$bad' refused" api_log_path "$bad"
done

echo "api config validation (provisioner.conf is sourced by root)"
for ok in "FPM_MAX_CHILDREN=8" "BASIC_AUTH_DEFAULT=true" "BACKUP_SCHEDULE=*/15 * * * *" "PREVIEW_BRANCHES=feature/* fix/*" \
          "NOTIFY_WEBHOOK=https://hooks.slack.com/services/T0/B0/xyz" "NOTIFY_WEBHOOK=" "NOTIFY_EVENTS=deploy-failure webhook-rejected" \
          "UPLOADS_BACKUP_VERSIONS_DAYS=0" "NODE_BUILD_MEMORY_MAX=1536M" "DEFAULT_PHP=8.4" "PREVIEW_DB_MODE=isolated" "RELEASES_KEEP=08"; do
    assert_ok "config accepts ${ok}" api_config_validate "${ok%%=*}" "${ok#*=}"
done
# shellcheck disable=SC2016,SC1003  # literal injection attempts, on purpose
for bad in 'BASE_DOMAIN=evil.com' 'SITES_ROOT=/tmp' 'DB_ADMIN_CREDENTIALS=/tmp/x' 'FPM_MAX_CHILDREN=$(id)' 'FPM_MAX_CHILDREN=`id`' \
           'DEFAULT_PHP=8.3"; id; "' "DEFAULT_PHP=8.3' x" 'NOTIFY_WEBHOOK=https://x/$(id)' 'NOTIFY_WEBHOOK=http://insecure' \
           'BACKUP_SCHEDULE=* * * * * root id' 'RELEASES_KEEP=0' 'RELEASES_KEEP=099' 'BASIC_AUTH_DEFAULT=yes' 'NOTIFY_EVENTS=everything' \
           'PREVIEW_DB_MODE=both' 'NODE_BUILD_MEMORY_MAX=lots' 'FPM_MAX_CHILDREN=5\'; do
    assert_fail "config refuses ${bad}" api_config_validate "${bad%%=*}" "${bad#*=}"
done
assert_fail "config refuses a newline" api_config_validate CLIENT_MAX_BODY_SIZE $'64m\nid'

echo "backup endpoint that already names the bucket"
assert_eq "DO origin endpoint" "https://tor1.digitaloceanspaces.com" "$(backup_endpoint_with_bucket https://dev1-db.tor1.digitaloceanspaces.com dev1-db)"
assert_eq "case-insensitive, trailing slash" "https://s3.us-east-1.amazonaws.com" "$(backup_endpoint_with_bucket https://My-Bucket.s3.us-east-1.amazonaws.com/ my-bucket)"
assert_fail "region endpoint is fine" backup_endpoint_with_bucket https://tor1.digitaloceanspaces.com dev1-db
assert_fail "bucket elsewhere in the host is fine" backup_endpoint_with_bucket https://s3.dev1-db.example.com dev1-db
assert_fail "MinIO host:port is fine" backup_endpoint_with_bucket http://objectstore:9000 ddeploy-test

echo "uploads-fetch sources (user@host:path)"
for ok in "deploy@old.example.com:" "deploy@old.example.com:/var/www/site/uploads" "www-data@10.0.0.5:public_html/uploads" \
          "u@h.example:~/uploads" "deploy@old.example.com:."; do
    assert_ok "source accepted: $ok" fetch_parse_source "$ok" 22
done
# shellcheck disable=SC2016  # literal injection attempts, on purpose
for bad in "old.example.com:/x" "deploy@-oProxyCommand=id:/x" "deploy@old.example.com:/x/../etc" "deploy@old.example.com:-e sh" \
           'deploy@old.example.com:/x;id' 'deploy@old.example.com:/x$(id)' 'deploy@old.example.com:/x y' "Root@old.example.com:/x" \
           "deploy@old_example.com:/x" 'deploy@old.example.com:`id`' "-l@old.example.com:/x"; do
    assert_fail "source refused: $bad" fetch_parse_source "$bad" 22
done
assert_fail "port 0 refused" fetch_parse_source "deploy@old.example.com:" 0
assert_fail "port 70000 refused" fetch_parse_source "deploy@old.example.com:" 70000
assert_ok "port 2222 accepted" fetch_parse_source "deploy@old.example.com:" 2222
assert_eq "rsync source, rrsync (empty path)" "deploy@h.example:./" "$(fetch_rsync_source deploy h.example 22 "")"
assert_eq "rsync source, absolute path" "deploy@h.example:/var/www/up/" "$(fetch_rsync_source deploy h.example 22 /var/www/up/)"
assert_eq "known_hosts id, port 22" "h.example" "$(fetch_host_id h.example 22)"
assert_eq "known_hosts id, other port" "[h.example]:2222" "$(fetch_host_id h.example 2222)"

echo "rclone_reason (why a backup failed)"
rr="$(mktemp)"
printf '2026/10/04 03:38:19 NOTICE : something\n2026/10/04 03:38:19 ERROR : a.sql.gz: Failed to copy: AccessDenied: Access Denied.\n2026/10/04 03:38:19 Failed to copy: AccessDenied: Access Denied.\n' > "$rr"
assert_eq "last error line, without rclone's timestamp" "Failed to copy: AccessDenied: Access Denied." "$(rclone_reason "$rr")"
: > "$rr"
assert_eq "nothing to say: empty" "" "$(rclone_reason "$rr")"
rm -f "$rr"

echo "config files: format and checks"
assert_eq "json" json "$(api_file_format config/config.local.json)"
assert_eq "php" php "$(api_file_format wp-config.php)"
assert_eq "yaml" yaml "$(api_file_format config/app.YML)"
assert_eq "env" env "$(api_file_format .env.local)"
assert_eq "other" text "$(api_file_format robots.txt)"
cf="$(mktemp)"
printf '{"a": 1}' > "$cf"; assert_eq "valid JSON passes" "" "$(api_files_check "$cf" json)"
printf '{"a": }' > "$cf"; assert_ok "invalid JSON explained" grep -q "invalid JSON" <(api_files_check "$cf" json)
printf 'A=1\n# c\nexport B="x"\n' > "$cf"; assert_eq "env passes" "" "$(api_files_check "$cf" env)"
printf 'A=1\nnot a pair\n' > "$cf"; assert_ok "env: the bad line named" grep -q "line 2" <(api_files_check "$cf" env)
printf 'a\0b' > "$cf"; assert_ok "binary refused" grep -q "UTF-8" <(api_files_check "$cf" text)
rm -f "$cf"

echo "cmd_db.sh"
assert_ok "snapshot id" validate_snapshot_id 20261002T143012Z-pre-import
assert_fail "snapshot id with a path" validate_snapshot_id '20261002T143012Z-../../x'
assert_fail "snapshot id without reason" validate_snapshot_id 20261002T143012Z

echo "cmd_api.sh validators"
assert_ok "actor email" api_valid_actor alice@example.com
assert_fail "actor without @" api_valid_actor alice
assert_fail "actor with space" api_valid_actor 'a b@example.com'
assert_fail "actor with semicolon" api_valid_actor 'a;b@example.com'
assert_ok "ssh:// repo" api_valid_repo_url ssh://git@github.com/org/repo.git
assert_ok "scp-style repo" api_valid_repo_url git@github.com:org/repo.git
assert_ok "https repo" api_valid_repo_url https://github.com/org/repo.git
assert_fail "file:// repo refused" api_valid_repo_url file:///etc
assert_fail "option-looking repo refused" api_valid_repo_url '--upload-pack=touch /tmp/x'
assert_fail "host starting with - refused" api_valid_repo_url 'ssh://-oProxyCommand=id/x'
assert_fail "user@-host refused" api_valid_repo_url 'ssh://git@-oProxyCommand=id/x'
assert_fail "repo with spaces refused" api_valid_repo_url 'git@github.com:org/repo.git; id'
# shellcheck disable=SC2016  # the $(...) must stay literal
assert_fail "repo with \$() refused" api_valid_repo_url 'https://x/$(id)'
assert_ok "hostname list" api_valid_each "alt www2" validate_hostname --hostnames
assert_fail "hostname list with injection" api_valid_each 'alt bad;host' validate_hostname --hostnames
assert_ok "upload dir with .." api_valid_upload_dir ../private-uploads --upload-dirs
assert_fail "absolute upload dir" api_valid_upload_dir /etc --upload-dirs
assert_ok "api_int caps at max" bash -c "source lib/common.sh; source lib/json.sh; source lib/cmd_api.sh; [[ \$(api_int 99999 10 500 x) == 500 ]]"
assert_ok "api_int default" bash -c "source lib/common.sh; source lib/json.sh; source lib/cmd_api.sh; [[ \$(api_int '' 10 500 x) == 10 ]]"
assert_fail "api_int refuses non-numbers" api_int 1e3 10 500 x

echo
echo "yqc (batched yq reads)"
# Every YQC_EXPRS expression must print exactly what `yq eval` prints —
# same bytes, same trailing newline, same "nothing at all" — on configs
# of every shape parse_config meets.
yqc_dir="$(mktemp -d)"
cat > "$yqc_dir/full.yaml" <<'EOF'
name: demo
php_version: "8.3"
docroot: ""
webserver_type: nginx-fpm
upload_dirs: [web/uploads, "private uploads", "@@yqc-fake 3"]
database: {name: dbn, user: ""}
additional_fqdns: [a.example.com]
additional_hostnames: []
basic_auth: true
client_max_body_size: 64M
composer_dev: false
fpm_max_children: 12
nodejs_version: auto
build:
  path: front
  package_manager: pnpm
  install: false
  script: build
  env: {A: 1, B: "x y", C: "multi\nline"}
  outputs: [dist, ""]
php_ini: {memory_limit: 256M}
redirects:
  - {from: /a, to: /b, code: 302}
schedule:
  - {cron: "* * * * *", cmd: "php craft queue/run"}
hooks:
  post-start:
    - exec: "npm run build"
    - composer: install
EOF
printf 'name: bare\n' > "$yqc_dir/bare.yaml"
printf 'build: true\nredirects: "nope"\nschedule: {}\nhooks: {}\n' > "$yqc_dir/odd.yaml"
: > "$yqc_dir/empty.yaml"
printf '# only a comment\n' > "$yqc_dir/comment.yaml"
yqc_mismatch=0
for f in "$yqc_dir"/{full,bare,odd,empty,comment}.yaml; do
    for e in "${YQC_EXPRS[@]}"; do
        want="$(yq eval "$e" "$f" 2>&1; printf '|%s' "$?")"
        got="$(yqc "$e" "$f" 2>&1; printf '|%s' "$?")"
        if [[ "$want" != "$got" ]]; then
            yqc_mismatch=$((yqc_mismatch + 1))
            bad "yqc '$e' on $(basename "$f"): expected $(printf %q "$want"), got $(printf %q "$got")"
        fi
    done
done
assert_eq "every expression matches yq on 5 config shapes" 0 "$yqc_mismatch"
assert_eq "an expression outside the list still works (real yq)" "front" "$(yqc '.build.path' "$yqc_dir/full.yaml")"

# One yq process per file, however many reads: count them with a shim.
mkdir -p "$yqc_dir/bin"
printf '#!/bin/sh\necho x >> "%s"\nexec %s "$@"\n' "$yqc_dir/calls" "$(command -v yq)" > "$yqc_dir/bin/yq"
chmod +x "$yqc_dir/bin/yq"
yqc_calls="$(
    PATH="$yqc_dir/bin:$PATH"
    : > "$yqc_dir/calls"
    yqc_prime "$yqc_dir/full.yaml"
    for e in "${YQC_EXPRS[@]}"; do v="$(yqc "$e" "$yqc_dir/full.yaml")"; done
    mapfile -t _dirs < <(yqc '.upload_dirs[]' "$yqc_dir/full.yaml")
    wc -l < "$yqc_dir/calls" | tr -d ' '
)"
assert_eq "primed: ${#YQC_EXPRS[@]} reads, one yq process" 1 "$yqc_calls"

# A write between reads is seen: the cache compares content every call.
cp "$yqc_dir/full.yaml" "$yqc_dir/live.yaml"
yqc_prime "$yqc_dir/live.yaml"
assert_eq "cached value" "8.3" "$(yqc '.php_version' "$yqc_dir/live.yaml")"
sed -i.bak 's/^php_version: .*/php_version: "8.4"/' "$yqc_dir/live.yaml"
assert_eq "a changed file is reloaded" "8.4" "$(yqc '.php_version' "$yqc_dir/live.yaml")"
yqc_prime "$yqc_dir/live.yaml"
assert_eq "...and re-primed in this shell" "8.4" "${YQC_VAL[${YQC_FILE_ID[$yqc_dir/live.yaml]}:${YQC_IDX[.php_version]}]}"

# Unparseable YAML isn't cached: real yq runs, with its own error.
printf 'name: [unclosed\n' > "$yqc_dir/broken.yaml"
want_rc=0; yq eval '.name' "$yqc_dir/broken.yaml" >/dev/null 2>&1 || want_rc=$?
got_rc=0; yqc '.name' "$yqc_dir/broken.yaml" >/dev/null 2>&1 || got_rc=$?
assert_eq "broken YAML fails like yq does" "$want_rc" "$got_rc"
rm -rf "$yqc_dir"

echo
echo "read index fingerprint"
idxroot="$(mktemp -d)"
_saved_state="$DDEPLOY_STATE"
_saved_events="$EVENTS_DIR"
_saved_generated="$GENERATED_DIR"
_saved_conf="$CONF_FILE"
DDEPLOY_STATE="$idxroot/state"
INDEX_DIR="$DDEPLOY_STATE/index"
SITES_ROOT="$idxroot/sites"
GENERATED_DIR="$idxroot/gen"
EVENTS_DIR="$idxroot/events"
CONF_FILE="$idxroot/provisioner.conf"
mkdir -p "$SITES_ROOT/mysite/.ddev" "$GENERATED_DIR" "$EVENTS_DIR" "$INDEX_DIR"
printf 'BASE_DOMAIN=example.test\n' > "$CONF_FILE"
printf 'name: mysite\nphp_version: "8.3"\n' > "$SITES_ROOT/mysite/.ddev/config.yaml"
# shellcheck source=lib/index.sh
source lib/index.sh
index_fingerprints mysite
mkdir -p "$INDEX_DIR"
printf '%s' "${INDEX_FP[mysite]}" > "$INDEX_DIR/mysite.fp"
: > "$INDEX_DIR/mysite.summary"
: > "$INDEX_DIR/mysite.row"
printf 'null\n\n' > "$INDEX_DIR/mysite.config"
assert_ok "a matching fingerprint is a hit" index_fresh mysite
if stat -c %n "$CONF_FILE" >/dev/null 2>&1; then
    printf 'name: mysite\nphp_version: "8.4"\n' > "$SITES_ROOT/mysite/.ddev/config.yaml"
    index_fingerprints mysite
    assert_fail "a touched config file is a miss" index_fresh mysite
else
    INDEX_FP[mysite]+=$'changed\n'
    assert_fail "a changed fingerprint is a miss" index_fresh mysite
fi
DDEPLOY_STATE="$_saved_state"
EVENTS_DIR="$_saved_events"
GENERATED_DIR="$_saved_generated"
CONF_FILE="$_saved_conf"
rm -rf "$idxroot"
unset _saved_state _saved_events _saved_generated _saved_conf

echo
echo "doctor snapshot: paging only on changes"
# shellcheck source=lib/cmd_doctor.sh
source lib/cmd_doctor.sh
posts="$(mktemp)"
notify_post() { printf '%s|%s|%s\n' "$2" "$3" "${4//$'\n'/;}" >> "$posts"; }
NOTIFY_WEBHOOK=https://example.invalid/hook BASE_DOMAIN=example.test
doctor_notify_transitions $'a|vhost\nb|database' $'a|vhost\nb|database'
assert_eq "nothing changed: no page" "" "$(cat "$posts")"
doctor_notify_transitions $'a|vhost' $'a|vhost\nc|cert (custom domain)'
assert_eq "a new failure pages once, naming it" "fail|doctor: 1 check(s) started failing on example.test|c: cert (custom domain)" "$(cat "$posts")"
: > "$posts"
doctor_notify_transitions $'a|vhost\nc|cert' $'c|cert'
assert_eq "a recovery is announced" "ok|doctor: 1 check(s) recovered on example.test|a: vhost" "$(cat "$posts")"
: > "$posts"
NOTIFY_WEBHOOK=""
doctor_notify_transitions "" $'a|vhost'
assert_eq "no webhook configured: silent" "" "$(cat "$posts")"
rm -f "$posts"
snapdir="$(mktemp -d)"
DOCTOR_SNAPSHOT_DIR="$snapdir"
doctor_snapshot_site "2026-10-04T10:00:00Z" '{"name":"mysite","worst":"warn","preview":null,"checks":[{"status":"warn","check":"cert","detail":"soon"}]}'
doctor_snapshot_health mysite
assert_eq "health read back from the snapshot" "warn 2026-10-04T10:00:00Z" "$DOCTOR_HEALTH_WORST $DOCTOR_HEALTH_AT"
doctor_snapshot_health never-checked
assert_eq "never checked: no health" "|" "$DOCTOR_HEALTH_WORST|$DOCTOR_HEALTH_AT"
doctor_snapshot_site "2026-10-04T10:00:00Z" '{"name":"../escape","worst":"ok"}'
assert_eq "a path-like name is never written" "" "$(find "$snapdir" -name '*escape*')"
rm -rf "$snapdir"

echo
echo "log lines: a tag after the timestamp, everywhere"
logdir="$(mktemp -d)"
LOG_DIR="$logdir"
LINE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z \[(info|ok|warn|error)\] +[^ ]'
log_line "$logdir/x.log" ok "deploy: done"
log_line "$logdir/x.log" error "deploy: FAILED"
log_line "$logdir/x.log" bogus "unknown level"
assert_eq "ok, error, and an unknown level as info, messages aligned" \
    "[ok]    deploy: done|[error] deploy: FAILED|[info]  unknown level" "$(cut -d' ' -f2- "$logdir/x.log" | paste -sd'|' -)"
site_log mysite "deploy: started"
site_log mysite "deploy: done" ok
assert_cmd() { if grep -qvE "$LINE_RE" "$1"; then bad "$2 — $(grep -vE "$LINE_RE" "$1" | head -1)"; else ok "$2"; fi; }
assert_cmd "$logdir/mysite.log" "site_log lines are timestamped and tagged (info by default)"
assert_eq "...with the level given" "[ok]" "$(tail -n 1 "$logdir/mysite.log" | cut -d' ' -f2)"
# shellcheck source=lib/cmd_hook.sh
source lib/cmd_hook.sh
WEBHOOK_LOG_ID=abcd1234
hook_log_write webhook.log ok "deploy testsite: OK @ 1a2b3c4 (3s)"
assert_cmd "$logdir/webhook.log" "webhook.log lines are tagged"
assert_eq "...tag first, then the delivery id" "[ok]    [abcd1234] deploy testsite: OK @ 1a2b3c4 (3s)" "$(cut -d' ' -f2- "$logdir/webhook.log")"
WEBHOOK_PENDING="github push testsite@main -> accepted: matches"
hook_log_other "nothing to do" 2>/dev/null
assert_cmd "$logdir/webhook-other.log" "webhook-other.log lines are tagged"
rm -rf "$logdir"

echo
echo "basic auth IP allowlist"
for v in 203.0.113.10 198.51.100.0/24 10.0.0.0/8 0.0.0.0/0 2001:db8::1 2001:db8::/32 ::1 fe80::/10; do
    assert_ok "accepted: $v" validate_ip_allow_entry "$v" test
done
for v in 256.1.1.1 1.2.3 1.2.3.4/33 1.2.3.4/ 2001:db8::/129 'example.com' '1.2.3.4; deny all' '1.2.3.4 "off"; }' '$remote_addr' ':::1' 'none'; do
    assert_fail "refused: $v" validate_ip_allow_entry "$v" test
done
# shellcheck source=lib/vhost.sh
source lib/vhost.sh
AUTH_ALLOW_IPS=(203.0.113.10 198.51.100.0/24); AUTH_EXEMPT_PATHS=()
out="$(build_auth_map_block my-site "")"
assert_eq "allowlist alone: geo sets the realm" 'geo $auth_realm_my_site {|    default "Restricted";|    203.0.113.10 "off";|    198.51.100.0/24 "off";|}' "$(paste -sd'|' - <<< "$out")"
AUTH_EXEMPT_PATHS=(/health)
out="$(build_auth_map_block my-site "_custom" /health)"
assert_eq "with exempt paths: the path map defaults to the geo variable" \
    'geo $auth_ip_my_site_custom {|    default "Restricted";|    203.0.113.10 "off";|    198.51.100.0/24 "off";|}|map $uri $auth_realm_my_site_custom {|    default $auth_ip_my_site_custom;|    ~^/health "off";|}' \
    "$(paste -sd'|' - <<< "$out")"
AUTH_ALLOW_IPS=(); AUTH_EXEMPT_PATHS=()
assert_eq "neither: no block at all" "" "$(build_auth_map_block my-site "")"
BASIC_AUTH_CREDENTIALS=/dev/null
AUTH_ALLOW_IPS=(203.0.113.10)
assert_eq "auth_basic takes the realm variable when there's an allowlist" \
    '    auth_basic $auth_realm_my_site;' "$(build_auth_block my-site true "" 2>/dev/null | head -1)"
AUTH_ALLOW_IPS=()

echo
echo "$PASSES passed, $FAILS failed"
[[ "$FAILS" -eq 0 ]]
