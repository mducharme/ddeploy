#!/usr/bin/env bash
# `api files`: a site's persistent config files, for the web UI's editor —
# the DB credential file when it isn't .env (charcoal's
# config/config.local.json) and the files declared in persistent_files
# (minus .env, which `api env` edits key by key).
#
# Every read and write of the file itself runs as the site's Linux user:
# the persistent store belongs to that user, who could replace a file with
# a symlink to anything; as that user, a symlink only reaches what the user
# could read or write anyway. Previous versions are kept root-only, outside
# the store (FILE_VERSIONS_DIR), so a bad edit can be put back.

FILE_VERSIONS_DIR="$DDEPLOY_STATE/file-versions"
API_FILE_MAX_BYTES=262144
API_FILE_VERSIONS_KEEP=10

# Format from a path's extension: what the editor checks before saving.
api_file_format() {
    case "${1,,}" in
        *.json) echo json ;;
        *.yml|*.yaml) echo yaml ;;
        *.php) echo php ;;
        *.env|*.env.*|.env*) echo env ;;
        *.ini|*.conf) echo ini ;;
        *) echo text ;;
    esac
}

# Sets FILES_TARGET FILES_OWNER and FILES_LIST[] (repo-relative paths) for $1.
api_files_resolve() {
    local name="$1"
    ( uploads_resolve_site "$name" ) >/dev/null 2>&1 || api_die conflict "can't read '$name's config — deploy it once first"
    uploads_resolve_site "$name" >/dev/null 2>&1
    FILES_TARGET="$UPX_TARGET"
    FILES_OWNER="$UPX_OWNER"
    FILES_CREDENTIAL="$(persistent_db_credential_path "$DB_ENV_SCHEME")"
    FILES_LIST=()
    [[ -n "$FILES_CREDENTIAL" && "$FILES_CREDENTIAL" != .env ]] && FILES_LIST+=("$FILES_CREDENTIAL")
    local f
    for f in "${PERSISTENT_FILES[@]}"; do
        [[ "$f" == */ || "$f" == .env ]] && continue
        [[ " ${FILES_LIST[*]} " == *" $f "* ]] || FILES_LIST+=("$f")
    done
}

# Dies unless $1 is one of FILES_LIST.
api_files_require() {
    local want="$1" f
    for f in "${FILES_LIST[@]}"; do [[ "$f" == "$want" ]] && return 0; done
    api_die bad_request "'$want' isn't one of '$FILES_TARGET's config files (${FILES_LIST[*]:-none})"
}

api_files_path() { printf '%s/%s/%s' "$PERSISTENT_ROOT" "$FILES_TARGET" "$1"; }
api_files_versions_dir() { printf '%s/%s/%s' "$FILE_VERSIONS_DIR" "$FILES_TARGET" "$(printf '%s' "$1" | tr '/' '%')"; }

# Reads $1 (absolute) as the site user into file $2, its size in
# FILES_READ_SIZE. Returns 1 if there's no such file; dies on anything
# else. Called directly, never in $(...): its api_die must end the request.
api_files_read_as_owner() {
    local file="$1" out="$2"
    sudo -u "$FILES_OWNER" -- test -f "$file" || return 1
    sudo -u "$FILES_OWNER" -- head -c "$((API_FILE_MAX_BYTES + 1))" -- "$file" > "$out" 2>/dev/null \
        || api_die error "couldn't read it as $FILES_OWNER"
    FILES_READ_SIZE="$(stat -c %s "$out")"
    (( FILES_READ_SIZE <= API_FILE_MAX_BYTES )) || api_die conflict "it's larger than $((API_FILE_MAX_BYTES / 1024)) KB — edit it on the server"
}

api_files_sha() { sha256sum "$1" | cut -d' ' -f1; }

# Checks file $1 as format $2; prints why it's refused, or nothing.
api_files_check() {
    local f="$1" format="$2"
    # A NUL byte (binary), or not valid UTF-8.
    if [[ "$(tr -d '\000' < "$f" | wc -c)" -ne "$(wc -c < "$f")" ]] || ! iconv -f UTF-8 -t UTF-8 "$f" >/dev/null 2>&1; then
        echo "it isn't UTF-8 text"; return
    fi
    case "$format" in
        json) python3 -c 'import json,sys
try: json.load(open(sys.argv[1], encoding="utf-8"))
except ValueError as e: print(f"invalid JSON: {e}")' "$f" ;;
        yaml) yq eval '.' "$f" >/dev/null 2>"$f.err" || sed 's/^Error: /invalid YAML: /' "$f.err" | head -n 1; rm -f "$f.err" ;;
        # php -l parses without running anything.
        php) php -l "$f" >/dev/null 2>"$f.err" || { local o; o="$(php -l "$f" 2>&1 | grep -v '^Errors parsing' | head -n 1)"; echo "${o:-PHP syntax error}" | sed "s#in $f#in the file#"; }; rm -f "$f.err" ;;
        env) awk 'NF && $0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=/ { printf "line %d isn'"'"'t KEY=value: %s\n", NR, $0; exit }' "$f" ;;
    esac
    # Called in $(...) under set -e: the message is the answer, never the exit status.
    return 0
}

# How $1 can be replaced safely. "owner": some folder on the way is the
# site user's, so the write happens as that user (whatever a symlink
# there points to, it only reaches the user's own files). "root": every
# folder from the site's store down is root's — the user can't swap the
# file for a symlink — so root writes a temp file there and renames it
# over (a rename replaces the entry, never follows it). A symlink among
# those folders is refused outright.
api_files_write_mode() {
    local dir; dir="$(dirname "$1")"
    local base="$PERSISTENT_ROOT/$FILES_TARGET" d
    d="$dir"
    while :; do
        [[ -L "$d" ]] && api_die conflict "refusing to write through '$d', a symlink"
        if sudo -u "$FILES_OWNER" -- test -w "$d"; then echo owner; return; fi
        [[ "$d" == "$base" || "$d" == / ]] && break
        d="$(dirname "$d")"
    done
    echo root
}

# api files <name>                          the editable config files
# api files <name> --read <path>            one, with its previous versions
# api files <name> --write <path> --actor a [--expect-sha s]   content on stdin
# api files <name> --restore <path> --version <id> --actor a
api_files() {
    local name="${1:-}"
    shift || true
    api_require_site "$name"
    local read="" write="" restore="" version="" actor="" expect=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --read) read="${2:-}"; shift ;;
            --write) write="${2:-}"; shift ;;
            --restore) restore="${2:-}"; shift ;;
            --version) version="${2:-}"; shift ;;
            --actor) actor="${2:-}"; shift ;;
            --expect-sha) expect="${2:-}"; shift ;;
            *) api_die bad_request "files: unknown option '$1'" ;;
        esac
        shift
    done
    api_files_resolve "$name"

    if [[ -z "$read$write$restore" ]]; then
        api_header
        printf ',"site":%s,"target":%s,"credential":%s,"files":[' "$(json_str "$name")" "$(json_str "$FILES_TARGET")" "$(json_str "$FILES_CREDENTIAL")"
        local f first=1 p size exists
        for f in "${FILES_LIST[@]}"; do
            p="$(api_files_path "$f")"
            exists=false size=null
            if sudo -u "$FILES_OWNER" -- test -f "$p"; then exists=true; size="$(sudo -u "$FILES_OWNER" -- stat -c %s -- "$p" 2>/dev/null || echo null)"; fi
            [[ "$first" -eq 1 ]] || printf ','
            first=0
            printf '{"path":%s,"format":%s,"exists":%s,"size":%s,"credential":%s}' "$(json_str "$f")" "$(json_str "$(api_file_format "$f")")" "$exists" "$size" \
                "$( [[ "$f" == "$FILES_CREDENTIAL" ]] && echo true || echo false )"
        done
        printf ']}\n'
        return
    fi

    local path="${read:-${write:-$restore}}"
    api_files_require "$path"
    local file; file="$(api_files_path "$path")"
    local vdir; vdir="$(api_files_versions_dir "$path")"
    local tmp; tmp="$(mktemp)"
    # They may hold credentials: gone however this ends (the api runs in a subshell of its own).
    # shellcheck disable=SC2064  # our own temp path, expanded now
    trap "rm -f '$tmp' '$tmp.new'" EXIT

    if [[ -n "$read" ]]; then
        local size=0 exists=true
        if api_files_read_as_owner "$file" "$tmp"; then size="$FILES_READ_SIZE"; else exists=false; : > "$tmp"; fi
        # $(...) drops trailing newlines; the "x" keeps the file exactly as it is.
        local content; content="$(cat "$tmp"; printf x)"; content="${content%x}"
        api_header
        printf ',"path":%s,"format":%s,"exists":%s,"size":%s,"sha256":%s,"content":%s,"versions":[' \
            "$(json_str "$path")" "$(json_str "$(api_file_format "$path")")" "$exists" "$size" "$(json_str "$(api_files_sha "$tmp")")" "$(json_str "$content")"
        local v first=1
        while IFS= read -r v; do
            [[ "$v" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || continue
            [[ "$first" -eq 1 ]] || printf ','
            first=0
            printf '{"id":%s,"size":%s,"by":%s}' "$(json_str "$v")" "$(stat -c %s "$vdir/$v")" "$(json_str "$(cat "$vdir/$v.by" 2>/dev/null || true)")"
        done < <(ls -1 "$vdir" 2>/dev/null | grep -v '\.by$' | sort -r)
        printf ']}\n'
        return
    fi

    api_valid api_valid_actor "$actor"
    if [[ -n "$restore" ]]; then
        [[ "$version" =~ ^[0-9]{8}T[0-9]{6}Z$ && -f "$vdir/$version" ]] || api_die not_found "no version '$version' of $path"
        cat "$vdir/$version" > "$tmp.new"
    else
        [[ ! -t 0 ]] || api_die bad_request "files --write reads the new content from stdin"
        head -c "$((API_FILE_MAX_BYTES + 1))" > "$tmp.new"
        (( $(stat -c %s "$tmp.new") <= API_FILE_MAX_BYTES )) || api_die bad_request "larger than $((API_FILE_MAX_BYTES / 1024)) KB"
    fi
    local why; why="$(api_files_check "$tmp.new" "$(api_file_format "$path")")"
    [[ -z "$why" ]] || api_die bad_request "not saved: $why"

    local had=false
    if api_files_read_as_owner "$file" "$tmp"; then had=true; fi
    if [[ -n "$expect" ]]; then
        local current; current="$( [[ "$had" == true ]] && api_files_sha "$tmp" || api_files_sha /dev/null )"
        [[ "$current" == "$expect" ]] || api_die conflict "$path changed since you opened it — reload it, then make your change again"
    fi
    if cmp -s "$tmp" "$tmp.new"; then
        api_header; printf ',"path":%s,"changed":false,"sha256":%s}\n' "$(json_str "$path")" "$(json_str "$(api_files_sha "$tmp.new")")"; return
    fi

    # The previous version first, root-only (it may hold credentials).
    if [[ "$had" == true ]]; then
        install -d -m 700 "$FILE_VERSIONS_DIR" "$FILE_VERSIONS_DIR/$FILES_TARGET" "$vdir"
        # One version per second: two saves within a second must not overwrite each other's backup.
        local id; id="$(date -u +%Y%m%dT%H%M%SZ)"
        while [[ -e "$vdir/$id" ]]; do sleep 1; id="$(date -u +%Y%m%dT%H%M%SZ)"; done
        install -m 600 "$tmp" "$vdir/$id"
        printf '%s\n' "$actor" > "$vdir/$id.by"
        local old
        while IFS= read -r old; do rm -f "$vdir/$old" "$vdir/$old.by"; done < <(ls -1 "$vdir" | grep -v '\.by$' | sort -r | tail -n +$((API_FILE_VERSIONS_KEEP + 1)))
    fi
    # Written as the site user, next to the file, then renamed over it:
    # PHP never reads half a file, and the mode stays what it was (600 by default).
    local mode group
    mode="$(sudo -u "$FILES_OWNER" -- stat -c %a -- "$file" 2>/dev/null || echo 600)"
    group="$(sudo -u "$FILES_OWNER" -- stat -c %G -- "$file" 2>/dev/null || echo www-data)"
    if [[ "$(api_files_write_mode "$file")" == owner ]]; then
        sudo -u "$FILES_OWNER" -- sh -c 'umask 077; cat > "$1.ddeploy-new" && chmod "$2" "$1.ddeploy-new" && mv -f "$1.ddeploy-new" "$1"' _ "$file" "$mode" < "$tmp.new" \
            || api_die error "couldn't write $path as $FILES_OWNER"
    else
        local t; t="$(mktemp "$(dirname "$file")/.ddeploy-new.XXXXXX")"
        cat "$tmp.new" > "$t" && chown "$FILES_OWNER:$group" "$t" && chmod "$mode" "$t" && mv -f "$t" "$file" \
            || { rm -f "$t"; api_die error "couldn't write $path"; }
    fi
    local verb; verb="$( [[ -n "$restore" ]] && echo "restored $path from $version" || echo "edited $path" )"
    DDEPLOY_TRIGGER="web ($actor)" event_record "$name" file-change succeeded "subject=$verb"
    site_log "$name" "files: $verb (web ($actor))"
    api_header
    printf ',"path":%s,"changed":true,"sha256":%s}\n' "$(json_str "$path")" "$(json_str "$(api_files_sha "$tmp.new")")"
}
