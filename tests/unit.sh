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
echo "$PASSES passed, $FAILS failed"
[[ "$FAILS" -eq 0 ]]
