#!/usr/bin/env bash
# `node-gc [--yes]` — remove Node versions under $NVM_ROOT that nothing
# uses any more. Versions pile up on their own: `init` refreshes each
# BASELINE_NODE major to its newest patch release (leaving the old patch
# installed), and a site that moves from one nodejs_version to another
# leaves the old one behind.
#
# A version is kept when anything could still need it:
#   - DEFAULT_NODE / BASELINE_NODE, and every provisioned site's (and
#     preview's) resolved version — what its next deploy would use;
#   - a generated queue-worker/schedule wrapper that has a version's bin
#     dir baked into its PATH (lib/queue.sh);
#   - a process currently executing out of it (an in-flight build, a
#     running worker);
#   - anything installed in the last hour — a deploy that just installed
#     a version its NEW release asks for isn't visible from the live
#     release's config yet.
# A site whose config can't be resolved at all stops the whole run:
# guessing what it needs is exactly how you delete the one it does.

NODE_GC_GRACE_MINUTES=60

usage_node_gc() {
    cat <<'EOF'
usage: ddeploy node-gc [--yes]

Removes Node versions under NVM_ROOT that no site, provisioner.conf
default, queue worker/schedule wrapper, or running process uses, and
that weren't installed in the last hour. Without --yes, only prints
what it would keep and remove.
EOF
}

# $1 spec -> the installed vX.Y.Z it resolves to right now, or nothing.
node_gc_resolve() {
    local v; v="$(nvm_cmd version "$1" 2>/dev/null || true)"
    if [[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s\n' "$v"
    fi
}

# $1 site name -> its NODE_VERSION_SPEC. Run in a subshell by the caller:
# parse_config can die() on a malformed config.
node_gc_site_spec() {
    local name="$1"
    if is_preview "$name"; then
        read_preview_meta "$name" || return 1
        resolve_preview_config "$name" "$PREVIEW_PROJECT" "$PREVIEW_MODE"
    else
        local cfg_path; cfg_path="$(resolve_config_path "$name")"
        [[ -n "$cfg_path" ]] || return 1
        parse_config "$name" "$cfg_path" 0
    fi
    printf '%s\n' "${NODE_VERSION_SPEC:-}"
}

cmd_node_gc() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage_node_gc; return 0; }
    load_conf
    require_root

    local yes=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes) yes=1 ;;
            -h|--help) usage_node_gc; return 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done

    [[ "$NODE_ENABLED" == "true" ]] || die "NODE_ENABLED=false — nothing to collect"
    [[ -f "$NVM_ROOT/nvm.sh" ]] || die "no nvm at $NVM_ROOT — nothing to collect"

    local -A keep=()
    local spec ver name site_path
    # Appends reason $2 to version $1's keep list, once.
    keep_for() {
        [[ ", ${keep[$1]:-}, " == *", $2, "* ]] && return 0
        keep[$1]="${keep[$1]:+${keep[$1]}, }$2"
    }

    for spec in $DEFAULT_NODE $BASELINE_NODE; do
        ver="$(node_gc_resolve "$spec")"
        [[ -n "$ver" ]] || continue
        keep_for "$ver" "provisioner.conf ($spec)"
    done

    local -a broken=()
    for site_path in "$SITES_ROOT"/*/; do
        [[ -d "$site_path" ]] || continue
        name="$(basename "$site_path")"
        is_provisioned "$name" || continue
        if ! spec="$(node_gc_site_spec "$name" 2>/dev/null)"; then
            broken+=("$name")
            continue
        fi
        [[ -n "$spec" ]] || continue
        ver="$(node_gc_resolve "$spec")"
        [[ -n "$ver" ]] || continue
        keep_for "$ver" "$name ($spec)"
    done
    if [[ "${#broken[@]}" -gt 0 ]]; then
        die "can't resolve the Node version of: ${broken[*]} — fix their config first (see 'doctor'); not collecting anything while a site's needs are unknown"
    fi

    local f
    for f in "$GENERATED_DIR"/*.worker-*.sh "$GENERATED_DIR"/*.schedule-*.sh; do
        [[ -f "$f" ]] || continue
        while IFS= read -r ver; do
            ver="${ver#versions/node/}"
            ver="${ver%/bin}"
            keep_for "$ver" "$(basename "$f")"
        done < <(grep -o 'versions/node/v[0-9][0-9.]*/bin' "$f" | sort -u)
    done

    local exe target
    for exe in /proc/[0-9]*/exe; do
        target="$(readlink "$exe" 2>/dev/null)" || continue
        case "$target" in
            "$NVM_ROOT"/versions/node/v*/bin/*)
                ver="${target#"$NVM_ROOT"/versions/node/}"
                ver="${ver%%/*}"
                keep_for "$ver" "running process"
                ;;
        esac
    done

    local -a remove=()
    local d
    for d in "$NVM_ROOT"/versions/node/v*/; do
        [[ -d "$d" ]] || continue
        ver="$(basename "$d")"
        if [[ -n "${keep[$ver]:-}" ]]; then
            printf '  keep    %-10s %s\n' "$ver" "${keep[$ver]}"
        elif [[ -n "$(find "$d" -maxdepth 0 -mmin "-$NODE_GC_GRACE_MINUTES" 2>/dev/null)" ]]; then
            printf '  keep    %-10s installed < %sm ago (a deploy may be using it)\n' "$ver" "$NODE_GC_GRACE_MINUTES"
        else
            printf '  remove  %s\n' "$ver"
            remove+=("$ver")
        fi
    done

    if [[ "${#remove[@]}" -eq 0 ]]; then
        log_info "node-gc: nothing to remove"
        return 0
    fi
    if [[ "$yes" -ne 1 ]]; then
        log_info "node-gc: dry run — re-run with --yes to remove ${#remove[@]} version(s)"
        return 0
    fi
    for ver in "${remove[@]}"; do
        if nvm_cmd uninstall "$ver" >&2; then
            rm -rf "$NVM_ROOT/.cache/bin/node-$ver-"*
            log_info "node-gc: removed $ver"
        else
            log_warn "node-gc: nvm uninstall $ver failed — left in place"
        fi
    done
}
