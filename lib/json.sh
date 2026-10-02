#!/usr/bin/env bash
# Minimal JSON emitters for the `api` subcommand (lib/cmd_api.sh) and the
# event log (lib/events.sh). Pure bash, no jq (not installed by `init`)
# and no python3 round-trip per value: these run once per field on
# every `api sites` row, so process startup would dominate.
#
# Only strings need escaping; every caller builds objects with printf
# from json_str/json_num/json_bool, never by splicing raw input.

# $1 as a quoted JSON string. Escapes \ and " and the common whitespace
# controls; every other C0 control byte is dropped (log text can carry
# stray \x1b/\b from build tools — never meaningful in the UI, and an
# unescaped one would make the whole document invalid).
json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    if [[ "$s" == *[$'\001'-$'\037']* ]]; then
        local LC_ALL=C
        s="${s//[$'\001'-$'\037']/}"
    fi
    printf '"%s"' "$s"
}

# $1 if it's a plain integer, else null.
json_num() {
    if [[ "$1" =~ ^-?[0-9]+$ ]]; then printf '%s' "$1"; else printf 'null'; fi
}

# true for "true"/"1"/"yes", false for anything else non-empty, null for "".
json_bool() {
    case "$1" in
        true|1|yes) printf 'true' ;;
        "") printf 'null' ;;
        *) printf 'false' ;;
    esac
}

# $1 as a JSON string, or null when empty.
json_str_or_null() {
    if [[ -n "$1" ]]; then json_str "$1"; else printf 'null'; fi
}

# Every argument as one JSON array of strings.
json_str_array() {
    local first=1 v
    printf '['
    for v in "$@"; do
        [[ "$first" -eq 1 ]] || printf ','
        first=0
        json_str "$v"
    done
    printf ']'
}

# Lines on stdin that are each already a JSON value, joined into one
# array. Blank lines are skipped.
json_lines_to_array() {
    local first=1 line
    printf '['
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$first" -eq 1 ]] || printf ','
        first=0
        printf '%s' "$line"
    done
    printf ']'
}

# A whole file (or what's on stdin, with "-") as one JSON string. For
# log text, which can be hundreds of KB: control bytes are stripped with
# tr first, so json_str's slow per-character fallback never triggers.
json_str_file() {
    local content
    content="$(tr -d '\000-\010\013\014\016-\037' < "$1"; printf x)"
    content="${content%x}"
    json_str "$content"
}
