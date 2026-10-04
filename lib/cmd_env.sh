#!/usr/bin/env bash
# `env <name> ...` — read and edit a site's .env without having to know
# where it really lives. The file PHP reads (<site>/current/.env) is a
# symlink into $PERSISTENT_ROOT/<name>/.env (see lib/persistent.sh), and
# editing the symlink directly trips people up: `sudoedit` refuses
# symlinks outright, and anything that writes a temp file then renames it
# over the path replaces the link with a plain file in one release, which
# the next deploy throws away. This command always writes the persistent
# file itself, in place, and puts its owner/mode back afterwards.

usage_env() {
    cat <<'EOF'
usage: ddeploy env <name> [KEY=value ...] [options]

Reads or changes <name>'s .env — the persistent copy under
PERSISTENT_ROOT that every release symlinks to, so a change survives
every later deploy. Works for branch previews too (they have their own
.env, seeded from their parent's at creation).

With no KEY=value and no option, same as --show.

options:
  --unset <KEY>   remove KEY (repeatable)
  --show          print the file, values of secret-looking keys masked
  --reveal        with --show: print every value as-is
  --edit          open the real file in $EDITOR (falls back to editor/vi)
  --path          print the real file's path and exit

PHP reads .env on every request, so changes are live immediately —
unless the app caches its config (Laravel's config:cache): redeploy then.
The DB_* / CRAFT_DB_* keys are written by ddeploy; changing the password
here does NOT change it in MariaDB (see README "Database credentials").
EOF
}

# Prints the persistent .env path for $1, dying with a hint when the
# site's .env isn't actually linked into the persistent store (a scheme
# that keeps DB credentials elsewhere, e.g. charcoal, and no
# persistent_files entry for .env).
env_file_for_site() {
    local name="$1"
    local root; root="$(site_root "$name")"
    [[ -d "$root" ]] || die "'$name' doesn't exist (no $root)"
    local link; link="$(site_dir "$name")/.env"
    local target="$PERSISTENT_ROOT/$name/.env"
    if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
        echo "$target"
        return
    fi
    if [[ -e "$link" && ! -L "$link" ]]; then
        die "'$name' has a .env, but it's a plain file in the checkout, not in the persistent store — a deploy would lose edits to it. Redeploy '$name' first (deploy / deploy-preview re-link it), or add .env to persistent_files ('ddeploy override $name persistent_files=.env')"
    fi
    die "'$name' has no persistent .env — its db_env_scheme keeps credentials elsewhere. Add it with 'ddeploy override $name persistent_files=.env' and redeploy"
}

# The Linux user PHP-FPM runs as for $1 — the parent's for a shared-mode
# preview (see lib/preview.sh), the site's own otherwise.
env_owner_for_site() {
    local name="$1"
    if read_preview_meta "$name" && [[ "$PREVIEW_MODE" == "shared" ]]; then
        echo "www-$PREVIEW_PROJECT"
    else
        echo "www-$name"
    fi
}

env_fix_perms() {
    local file="$1" owner="$2"
    chown "$owner:www-data" "$file"
    chmod 600 "$file"
}

# Masks values of keys whose name looks like a credential.
env_show() {
    local file="$1" reveal="$2" line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$reveal" -eq 1 || "$line" != *=* || "$line" == \#* ]]; then
            printf '%s\n' "$line"
            continue
        fi
        key="${line%%=*}"
        val="${line#*=}"
        if [[ -n "$val" ]] && printf '%s' "$key" | grep -qiE 'PASS|SECRET|KEY|TOKEN|SALT|PRIVATE'; then
            printf '%s=******** (%d chars)\n' "$key" "${#val}"
        else
            printf '%s\n' "$line"
        fi
    done < "$file"
}

env_validate_key() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid .env key '$1' (letters, digits and _ only, not starting with a digit)"
}

cmd_env() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_env; return 0; }
    load_conf
    require_root

    local name="${1:-}"
    [[ -n "$name" ]] || { usage_env; die "site name required"; }
    shift
    validate_name "$name"

    local -a sets=() unsets=()
    local show=0 reveal=0 edit=0 path_only=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --unset) [[ -n "${2:-}" ]] || die "--unset needs a key"; unsets+=("$2"); shift ;;
            --show) show=1 ;;
            --reveal) reveal=1; show=1 ;;
            --edit) edit=1 ;;
            --path) path_only=1 ;;
            -h|--help) usage_env; return 0 ;;
            *=*) sets+=("$1") ;;
            *) usage_env; die "unrecognized argument: $1" ;;
        esac
        shift
    done

    local file; file="$(env_file_for_site "$name")"
    if [[ "$path_only" -eq 1 ]]; then
        echo "$file"
        return 0
    fi
    local owner; owner="$(env_owner_for_site "$name")"
    touch "$file"

    local kv key val
    for kv in "${sets[@]}"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        env_validate_key "$key"
        [[ "$val" != *$'\n'* && "$val" != *$'\r'* ]] || die "value for $key contains a newline — refusing to write it"
        if [[ "$key" =~ ^(CRAFT_)?DB_ ]]; then
            log_warn "$key is written by ddeploy from the site's real DB grant — changing it here doesn't change MariaDB"
        fi
        write_env_var "$file" "$key" "$val"
        log_info "'$name': set $key"
    done
    for key in "${unsets[@]}"; do
        env_validate_key "$key"
        unset_env_var "$file" "$key"
        log_info "'$name': unset $key"
    done

    if [[ "$edit" -eq 1 ]]; then
        # Edit a private copy, then write it back in place — an editor
        # saving via rename would otherwise leave the real file root-owned
        # (or worse, replace a symlink if pointed at the site's own path).
        local editor="${VISUAL:-${EDITOR:-}}"
        if [[ -z "$editor" ]]; then
            if command -v editor >/dev/null 2>&1; then editor=editor; else editor=vi; fi
        fi
        local tmp; tmp="$(mktemp)"
        chmod 600 "$tmp"
        cat "$file" > "$tmp"
        # Word-splitting intended: EDITOR="code --wait" is common.
        # shellcheck disable=SC2086
        $editor "$tmp" || { rm -f "$tmp"; die "editor exited non-zero — .env left unchanged"; }
        if grep -nvE '^[[:space:]]*($|#|[A-Za-z_][A-Za-z0-9_]*=)' "$tmp" >/dev/null; then
            log_warn "some lines don't look like KEY=value (kept anyway):"
            grep -nvE '^[[:space:]]*($|#|[A-Za-z_][A-Za-z0-9_]*=)' "$tmp" | sed 's/=.*/=…/' >&2
        fi
        cat "$tmp" > "$file"
        rm -f "$tmp"
        log_info "'$name': saved $file"
    fi

    env_fix_perms "$file" "$owner"

    # Key names only: values are secrets, and events are shown in the UI.
    if [[ "${#sets[@]}" -gt 0 || "${#unsets[@]}" -gt 0 || "$edit" -eq 1 ]]; then
        local summary=""
        local -a set_keys=()
        for kv in "${sets[@]}"; do set_keys+=("${kv%%=*}"); done
        [[ "${#set_keys[@]}" -gt 0 ]] && summary="set ${set_keys[*]}"
        [[ "${#unsets[@]}" -gt 0 ]] && summary+="${summary:+, }unset ${unsets[*]}"
        [[ "$edit" -eq 1 ]] && summary+="${summary:+, }edited"
        event_record "$name" env-change succeeded "subject=$summary"
    fi

    if [[ "$show" -eq 1 || ( "${#sets[@]}" -eq 0 && "${#unsets[@]}" -eq 0 && "$edit" -eq 0 ) ]]; then
        log_info "$file (symlinked from $(site_dir "$name")/.env)"
        env_show "$file" "$reveal"
    fi
}
