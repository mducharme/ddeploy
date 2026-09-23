#!/usr/bin/env bash
# `override <name> key=value ...` — an operator-side override for
# .ddeploy/config.yaml-style settings, without touching the client repo.
# Written to generated/<name>.override.yaml and always wins over both
# .ddeploy/config.yaml and .ddev/config.yaml (see read_ext_scalar/
# read_ext_array in lib/config.sh). Takes effect on the site's next
# `deploy` — re-run it yourself if you need it applied right away. See
# README "Overriding a project's config without touching the repo".

# Scalar keys: no dedicated validator beyond what parse_config itself
# applies to the same key when it comes from the repo (client_max_body_size/
# fpm_max_children/db_env_scheme/db_backup_retention_days aren't strictly
# validated there either — matching that, not inventing stricter behavior
# for this path alone).
OVERRIDE_SCALAR_KEYS="basic_auth client_max_body_size fpm_max_children db_env_scheme security_headers static_cache deny_php_in_uploads db_backup_retention_days"
# Array keys: space-separated on the CLI, same as --hostnames/--upload-dirs
# elsewhere in this tool.
OVERRIDE_ARRAY_KEYS="additional_hostnames additional_fqdns persistent_files auth_exempt_paths backup_exclude deny_php_paths"

usage_override() {
    cat <<EOF
usage: provision.sh override <name> [key=value ...] [options]

Sets an operator-side override for .ddeploy/config.yaml-style settings —
server-side only, never written into the client repo. Always wins over
both .ddeploy/config.yaml and .ddev/config.yaml. Takes effect on the
site's next deploy.

Scalar keys (one value): $OVERRIDE_SCALAR_KEYS
List keys (space-separated value, quote it): $OVERRIDE_ARRAY_KEYS

Not supported here: redirects, php_ini, queue_workers, schedule —
structured data (or, for queue_workers, a command very likely to contain
its own spaces) that doesn't fit a flat key=value; set those in
.ddeploy/config.yaml in the repo.

options:
  --unset <key>   remove one override key (repeatable)
  --show          print this site's current overrides and exit
  --clear         remove every override for this site
EOF
}

override_key_kind() {
    local key="$1" k
    for k in $OVERRIDE_SCALAR_KEYS; do [[ "$k" == "$key" ]] && { echo scalar; return; }; done
    for k in $OVERRIDE_ARRAY_KEYS; do [[ "$k" == "$key" ]] && { echo array; return; }; done
    echo ""
}

# $1 name (for error labels) $2 key $3 value — dies on an invalid value,
# reusing the same validators parse_config applies to the same key when
# it comes from the repo. Values are interpolated straight into a yq
# expression string ("$key = \"$val\""), so a literal double quote would
# break out of that string literal — reject it outright, on top of
# whatever the per-key validator below already enforces.
override_validate_value() {
    local name="$1" key="$2" val="$3"
    [[ "$val" != *'"'* ]] || die "$key for '$name' cannot contain a double quote"
    case "$key" in
        basic_auth|security_headers|deny_php_in_uploads) validate_bool "$val" "$key for '$name'" ;;
        static_cache) validate_static_cache "$val" "$key for '$name'" ;;
        additional_hostnames|additional_fqdns) validate_hostname "$val" "$key entry for '$name'" ;;
        persistent_files) validate_relative_path "${val%/}" "$key entry for '$name'" ;;
        auth_exempt_paths|deny_php_paths) validate_url_path "$val" "$key entry for '$name'" ;;
        backup_exclude) [[ "$val" != *$'\n'* ]] || die "$key entry for '$name' contains a newline — refusing to use it" ;;
        *) [[ "$val" != *$'\n'* ]] || die "$key for '$name' contains a newline — refusing to use it" ;;
    esac
}

cmd_override() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_override; return 0; }
    load_conf
    require_root

    local name="${1:-}"
    [[ -n "$name" ]] || { usage_override; die "site name required"; }
    shift
    validate_name "$name"

    local f; f="$(override_config_path "$name")"
    local -a sets=() unsets=()
    local show=0 clear=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --unset) [[ -n "${2:-}" ]] || die "--unset needs a key"; unsets+=("$2"); shift ;;
            --show) show=1 ;;
            --clear) clear=1 ;;
            -h|--help) usage_override; return 0 ;;
            *=*) sets+=("$1") ;;
            *) usage_override; die "unrecognized argument: $1" ;;
        esac
        shift
    done

    if [[ "$clear" -eq 1 ]]; then
        rm -f "$f"
        log_info "cleared all overrides for '$name'"
    fi

    if [[ "${#sets[@]}" -eq 0 && "${#unsets[@]}" -eq 0 ]]; then
        [[ "$show" -eq 1 || "$clear" -eq 1 ]] \
            || { usage_override; die "nothing to do — give key=value, --unset <key>, --show, or --clear"; }
    else
        require_yq
        mkdir -p "$GENERATED_DIR"
        [[ -s "$f" ]] || echo "{}" > "$f"

        local kv key val kind v
        for kv in "${sets[@]}"; do
            key="${kv%%=*}"
            val="${kv#*=}"
            kind="$(override_key_kind "$key")"
            [[ -n "$kind" ]] || die "unknown override key '$key' — see 'provision.sh override -h' for the supported list"
            if [[ "$kind" == "array" ]]; then
                local -a items=()
                read -ra items <<< "$val"
                for v in "${items[@]}"; do override_validate_value "$name" "$key" "$v"; done
                yq eval -i ".${key} = []" "$f"
                for v in "${items[@]}"; do
                    yq eval -i ".${key} += [\"${v}\"]" "$f"
                done
            else
                override_validate_value "$name" "$key" "$val"
                yq eval -i ".${key} = \"${val}\"" "$f"
            fi
            log_info "'$name': set override $key"
        done
        for key in "${unsets[@]}"; do
            kind="$(override_key_kind "$key")"
            [[ -n "$kind" ]] || die "unknown override key '$key' — see 'provision.sh override -h' for the supported list"
            yq eval -i "del(.${key})" "$f"
            log_info "'$name': unset override $key"
        done
    fi

    if [[ "$show" -eq 1 ]]; then
        if [[ -s "$f" ]]; then
            cat "$f"
        else
            log_info "no overrides set for '$name'"
        fi
    fi
}
