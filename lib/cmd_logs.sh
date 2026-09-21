#!/usr/bin/env bash
# `logs <name>` — last lines of $LOG_DIR/<name>.log. Site names and the
# fleet logs init writes (backup-uploads, backup-database, prune-previews)
# all match NAME_RE, so one validator covers both. Never interpolates
# $name into a path without that check (a `../` would otherwise walk
# out of LOG_DIR).

usage_logs() {
    cat <<'EOF'
usage: provision.sh logs <name> [-n lines] [-f]

Print the last lines of logs/<name>.log (provision/deploy/preview for a
site, or backup-uploads / backup-database / prune-previews for fleet
cron). -n is how many (default 50). -f follows, like tail -f.

<name> must be a plain site/log name (same charset as provision).
EOF
}

cmd_logs() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_logs; return 0; }
    load_conf
    require_root

    local name="" follow=0 lines=50
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--follow) follow=1 ;;
            -n|--lines)
                [[ -n "${2:-}" ]] || die "logs: -n needs a line count"
                lines="$2"
                shift
                ;;
            -h|--help) usage_logs; return 0 ;;
            -*) die "unknown option: $1" ;;
            *)
                [[ -z "$name" ]] || die "logs: extra argument '$1'"
                name="$1"
                ;;
        esac
        shift
    done

    [[ -n "$name" ]] || { usage_logs; die "name required"; }
    validate_name "$name"
    [[ "$lines" =~ ^[1-9][0-9]{0,4}$ ]] || die "logs: -n must be 1–99999"

    local file="$LOG_DIR/$name.log"
    [[ -f "$file" ]] || die "no log at $file"

    if [[ "$follow" -eq 1 ]]; then
        exec tail -n "$lines" -F "$file"
    fi
    tail -n "$lines" "$file"
}
