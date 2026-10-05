#!/usr/bin/env bash
# `api deploy-check` / `api errors`: answers for "is a deploy going to
# change anything?" and "what is this site complaining about?".

# api deploy-check <name>: the tracked branch's head on the remote vs what's
# live — so a deploy confirmation can say "up to date" or "new commits".
# One `git ls-remote`, nothing fetched.
api_deploy_check() {
    local name="${1:-}"
    [[ $# -le 1 ]] || api_die bad_request "deploy-check takes one site name"
    api_require_site "$name"
    local dir; dir="$(site_dir "$name")"
    local branch live remote="" reachable=true
    branch="$(read_deploy_branch "$name" 2>/dev/null || true)"
    [[ -n "$branch" ]] || branch="$(git -c safe.directory='*' -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    live="$(git -c safe.directory='*' -C "$dir" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$branch" ]]; then
        remote="$(GIT_SSH_COMMAND="$(git_ssh_command)" GIT_TERMINAL_PROMPT=0 timeout 30 \
            git -c safe.directory='*' -C "$dir" ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1 | head -n 1 || true)"
        [[ -n "$remote" ]] || reachable=false
    fi
    local up=null
    [[ -n "$remote" && -n "$live" ]] && { [[ "$remote" == "$live" ]] && up=true || up=false; }
    # When the remote head is already here (an older deploy fetched it, or a
    # rollback went past it): how many commits it is ahead of live.
    local ahead=null
    if [[ "$up" == false ]] && git -c safe.directory='*' -C "$dir" cat-file -e "$remote^{commit}" 2>/dev/null; then
        ahead="$(git -c safe.directory='*' -C "$dir" rev-list --count "$live..$remote" 2>/dev/null || echo null)"
    fi
    api_header
    printf ',"site":%s,"branch":%s,"live_sha":%s,"remote_sha":%s,"up_to_date":%s,"ahead":%s,"reachable":%s}\n' \
        "$(json_str "$name")" "$(json_str_or_null "$branch")" "$(json_str_or_null "$live")" "$(json_str_or_null "$remote")" "$up" "$ahead" "$reachable"
}

# api errors <name> [--since <ISO time>] [--limit N]: the site's errors
# from its nginx error log (PHP's arrive there through FastCGI), grouped
# by message — the same fatal repeated 4,000 times is one line with its
# count, not 4,000 lines hiding everything else. Default: the last 24h.
api_errors() {
    local name="${1:-}"
    shift || true
    api_require_site "$name"
    local since="" limit=20
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --since) since="${2:-}"; shift ;;
            --limit) limit="$(api_int "${2:-}" 20 100 --limit)"; shift ;;
            *) api_die bad_request "errors: unknown option '$1'" ;;
        esac
        shift
    done
    [[ -z "$since" || "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || api_die bad_request "--since takes an ISO time like 2026-10-04T12:00:00Z"
    local file="/var/log/nginx/$name.error.log"
    api_header
    printf ',"site":%s,"log":%s,"since":' "$(json_str "$name")" "$(json_str "$name.error")"
    # The last 20 MB at most: enough for a day of a noisy site, bounded for a huge one.
    { [[ -f "$file" ]] && tail -c 20000000 "$file" || true; } | python3 -c '
import json, re, sys, datetime
since_arg, limit = sys.argv[1], int(sys.argv[2])
now = datetime.datetime.utcnow()
since = datetime.datetime.strptime(since_arg, "%Y-%m-%dT%H:%M:%SZ") if since_arg else now - datetime.timedelta(hours=24)
line_re = re.compile(r"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) \[(\w+)\] \d+#\d+: (?:\*\d+ )?(.*)$")
groups = {}
total = 0
for raw in sys.stdin:
    m = line_re.match(raw.rstrip("\n"))
    if not m:
        continue
    when = datetime.datetime.strptime(m.group(1), "%Y/%m/%d %H:%M:%S")
    if when < since:
        continue
    level, rest = m.group(2), m.group(3)
    request = None
    rm = re.search(r", request: \"([^\"]*)\"", rest)
    if rm:
        request = rm.group(1)
    msg = rest
    php = re.search(r"PHP message: (.*?)(?:\" while reading|; PHP message:|$)", rest)
    if php:
        msg = php.group(1)
    else:
        msg = re.split(r", client: ", msg)[0]
    msg = msg.strip()
    severity = "error"
    if re.search(r"PHP (Warning|Notice|Deprecated)", msg):
        severity = "warning"
    elif level in ("warn", "notice", "info"):
        severity = "warning"
    # The same error from different requests: one group (numbers that vary per request dropped).
    key = re.sub(r"\b\d{3,}\b", "N", msg)
    g = groups.get(key)
    stamp = when.strftime("%Y-%m-%dT%H:%M:%SZ")
    if not g:
        g = groups[key] = {"message": msg[:400], "severity": severity, "count": 0, "first_seen": stamp, "last_seen": stamp, "request": request}
    g["count"] += 1
    g["last_seen"] = stamp
    if request:
        g["request"] = request
    total += 1
top = sorted(groups.values(), key=lambda g: (g["severity"] != "error", -g["count"]))[:limit]
print(json.dumps(since.strftime("%Y-%m-%dT%H:%M:%SZ")) + ",\"total\":" + str(total) + ",\"groups\":" + json.dumps(top) + "}")
' "$since" "$limit"
}
