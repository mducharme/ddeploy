#!/usr/bin/env bash
# `hook-worker` — drain the webhook spool. Invoked by the systemd path
# unit (and by tests). Not a public operator command; argv passed to
# provision.sh is constructed here from an already-verified, already-
# parsed internal job, never from forge JSON directly.
#
# Every delivery and every action it leads to gets a line in
# logs/webhook.log (`provision.sh logs webhook`), tagged with a short
# delivery id so one push's lines can be followed through: received ->
# verified/rejected/ignored -> per-site skip/deploy OK/FAILED.

# Short tag for the delivery being processed — the forge's own delivery
# id when it sent one (matches what GitHub/Bitbucket show in their
# webhook UI), else the spool file's random id.
WEBHOOK_LOG_ID=""

# $1 info|warn|error, rest message. To the journal (as before) and to
# logs/webhook.log.
hook_log() {
    local level="$1"; shift
    case "$level" in
        warn) log_warn "webhook: $*" ;;
        error) log_error "webhook: $*" ;;
        *) log_info "webhook: $*" ;;
    esac
    mkdir -p "$LOG_DIR"
    printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${WEBHOOK_LOG_ID:--}" "$*" >> "$LOG_DIR/webhook.log"
}

# $1 verify_and_spool.py JSON report, $2 yq path. Empty if absent.
hook_report_field() {
    printf '%s' "$1" | yq -p=json eval "$2 // \"\"" - 2>/dev/null || true
}

cmd_hook_worker() {
    load_conf
    require_root

    local spool="$WEBHOOK_QUEUE_ROOT/new"
    local failed="$WEBHOOK_QUEUE_ROOT/failed"
    mkdir -p "$spool" "$failed"

    # Same resolution install_webhook (lib/hook.sh) uses — this is the
    # one and only place these paths get read as root, since the
    # listener itself never touches them (see lib/hook.sh's file header).
    local secret_path="${WEBHOOK_SECRET:-$WEBHOOK_SECRET_DEFAULT}"
    local secret_bb="${WEBHOOK_SECRET_BITBUCKET:-}"

    local f claimed
    # Loop until empty so a job arriving while we run isn't missed if the
    # path unit only fires once per "became non-empty" edge.
    # Do not "recover" .processing-* files here: a concurrent worker
    # (systemd path unit vs an explicit hook-worker) may still be using
    # that path. A crashed claim is left for the next operator/doctor.
    while true; do
        shopt -s nullglob
        local files=("$spool"/raw-*.json)
        shopt -u nullglob
        [[ "${#files[@]}" -eq 0 ]] && break
        for f in "${files[@]}"; do
            [[ -f "$f" ]] || continue
            claimed="$spool/.processing-$(basename "$f").$$.$RANDOM"
            mv "$f" "$claimed" 2>/dev/null || continue
            hook_verify_and_process "$claimed" "$secret_path" "$secret_bb" "$failed"
        done
    done
}

# $1 claimed raw envelope path, $2/$3 secret paths, $4 failed dir. Runs
# verify_and_spool.py (root context — the envelope's own provider/
# sig_header/forge_event/body are never trusted directly) and dispatches
# on its exit code. See hook/verify_and_spool.py's own docstring for
# what each code means.
hook_verify_and_process() {
    local claimed="$1" secret_path="$2" secret_bb="$3" failed="$4"
    # NOT a bare `[[ ]] && extra=(...)` statement — secret_bb is empty in
    # the common case (Bitbucket secret is optional), and under set -e a
    # bare statement whose condition is routinely false would silently
    # kill the whole worker the moment that happens (bitten by exactly
    # this pattern twice already elsewhere in this codebase).
    local -a extra=()
    if [[ -n "$secret_bb" ]]; then
        extra=(--secret-bitbucket "$secret_bb")
    fi

    local report rc=0
    report="$(python3 "$PROVISIONER_DIR/hook/verify_and_spool.py" "$claimed" --secret "$secret_path" "${extra[@]}")" || rc=$?

    local delivery; delivery="$(hook_report_field "$report" '.meta.delivery')"
    if [[ -n "$delivery" ]]; then
        WEBHOOK_LOG_ID="${delivery:0:8}"
    elif [[ "$(basename "$claimed")" =~ ^\.processing-raw-([0-9a-f]{8}) ]]; then
        WEBHOOK_LOG_ID="${BASH_REMATCH[1]}"
    else
        WEBHOOK_LOG_ID="--------"
    fi

    # "github push repo=org/site branch=main by=someone from=1.2.3.4"
    local summary f v
    summary="$(hook_report_field "$report" '.meta.provider') $(hook_report_field "$report" '.meta.forge_event')"
    for f in repo branch action actor remote; do
        v="$(hook_report_field "$report" ".meta.$f")"
        [[ -n "$v" ]] || continue
        case "$f" in
            actor) summary+=" by=$v" ;;
            remote) summary+=" from=$v" ;;
            *) summary+=" $f=$v" ;;
        esac
    done
    local result; result="$(hook_report_field "$report" '.result')"
    local reason; reason="$(hook_report_field "$report" '.reason')"

    case "$rc" in
        2)
            hook_log warn "$summary -> REJECTED: HMAC verification failed (the secret in the forge's webhook settings doesn't match $secret_path, or this isn't a genuine delivery) — dropped"
            rm -f "$claimed"
            return
            ;;
        1)
            # Default set outside the "${...}": an apostrophe inside a
            # double-quoted ${var:-word} is a quote character to bash.
            [[ -n "$reason" ]] || reason="could not verify/parse the request"
            hook_log warn "$summary -> REJECTED: $reason — dropped"
            rm -f "$claimed"
            return
            ;;
        0) : ;;
        *)
            hook_log warn "$summary -> REJECTED: verify_and_spool.py exited $rc unexpectedly — dropped"
            rm -f "$claimed"
            return
            ;;
    esac

    if [[ "$result" != "job" ]]; then
        # Verified, but nothing actionable (ping, a deleted branch, a
        # closed-and-uninteresting PR, ...) — success, not a failure.
        hook_log info "$summary -> ignored: ${reason:-nothing to do}"
        rm -f "$claimed"
        return
    fi
    hook_log info "$summary -> accepted: $reason"

    local job_file="$claimed.job"
    printf '%s' "$report" | yq -p=json -o=json -I=0 eval '.job' - > "$job_file"
    if ! hook_process_job "$job_file"; then
        hook_log error "job failed — kept at $failed/$(basename "$job_file") for inspection"
        mv -f "$job_file" "$failed/" || rm -f "$job_file"
    else
        rm -f "$job_file"
    fi
    rm -f "$claimed"
}

# $1 label (deploy, deploy-preview, ...) $2 site, rest the command to
# run under that site's lock. Logs start and outcome (with the new sha
# and duration, or the tail of the site's own log on failure) to
# webhook.log, and pages NOTIFY_WEBHOOK on failure.
hook_run_site() {
    local label="$1" site="$2"; shift 2
    local started="$SECONDS" rc=0
    hook_log info "$label $site: started"
    with_site_lock "$site" "$@" || rc=$?
    local took=$((SECONDS - started))
    if [[ "$rc" -eq 0 ]]; then
        if tail -n 1 "$LOG_DIR/$site.log" 2>/dev/null | grep -q 'skipped (--if-changed)'; then
            hook_log info "$label $site: already up to date — nothing to do (${took}s)"
        elif [[ "$label" == remove-preview ]]; then
            hook_log info "$label $site: OK (${took}s)"
        else
            local sha; sha="$(git -c safe.directory='*' -C "$(site_dir "$site")" log -1 --format=%h 2>/dev/null || true)"
            hook_log info "$label $site: OK${sha:+ @ $sha} (${took}s)"
        fi
    else
        hook_log error "$label $site: FAILED (exit $rc, ${took}s) — $(notify_log_snippet "$LOG_DIR/$site.log") — full log: provision.sh logs $site"
        notify_failure "$label" "$site" "$(notify_log_snippet "$LOG_DIR/$site.log")"
    fi
    return "$rc"
}

# Reads one job file, maps event → existing CLI. Returns nonzero if any
# invoked command failed; unknown remotes are success (org hooks).
hook_process_job() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    require_yq
    local event branches_raw urls_raw provider pr
    event="$(yq eval '.event // ""' "$f")"
    provider="$(yq eval '.provider // ""' "$f")"
    pr="$(yq eval '.pr // ""' "$f")"
    [[ "$pr" == "null" ]] && pr=""
    branches_raw="$(yq eval '.branches[]' "$f" 2>/dev/null | grep -vx 'null' || true)"
    urls_raw="$(yq eval '.repo_urls[]' "$f" 2>/dev/null | grep -vx 'null' || true)"

    case "$event" in
        push_head|preview_upsert|preview_remove) ;;
        *)
            hook_log warn "unknown event '$event' — dropping"
            return 0
            ;;
    esac

    local -a branches=() urls=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && branches+=("$line")
    done <<< "$branches_raw"
    while IFS= read -r line; do
        [[ -n "$line" ]] && urls+=("$line")
    done <<< "$urls_raw"

    if [[ "${#urls[@]}" -eq 0 ]]; then
        hook_log warn "job has no repo urls — dropping"
        return 0
    fi

    local -a matches=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && matches+=("$line")
    done < <(matching_sites_for_urls "${urls[@]}")

    if [[ "${#matches[@]}" -eq 0 ]]; then
        hook_log info "no provisioned site uses ${urls[0]} — nothing to do"
        return 0
    fi

    local name branch parent preview head target hit extra failures=0
    case "$event" in
        push_head)
            for name in "${matches[@]}"; do
                is_preview "$name" && continue
                head="$(site_head_branch "$name")"
                # Also match the site's deploy_branch override (README
                # "Default branch"), not just its current HEAD — otherwise
                # the very first push after an operator sets `provision
                # --branch` would be ignored, since HEAD only moves once
                # deploy itself performs the switch, which this push is
                # meant to trigger in the first place.
                target="$(read_deploy_branch "$name")"
                hit=0
                for branch in "${branches[@]}"; do
                    if [[ "$head" == "$branch" ]] || [[ -n "$target" && "$target" == "$branch" ]]; then
                        hit=1; break
                    fi
                done
                if [[ "$hit" -ne 1 ]]; then
                    hook_log info "skip $name: it deploys '${target:-$head}', push was to ${branches[*]}"
                    continue
                fi
                if ! hook_run_site deploy "$name" "$PROVISIONER_DIR/provision.sh" deploy "$name" --if-changed; then
                    failures=$((failures + 1))
                fi
            done
            ;;
        preview_upsert)
            branch="${branches[0]:-}"
            [[ -n "$branch" ]] || { hook_log warn "preview_upsert missing branch — dropping"; return 0; }
            for parent in "${matches[@]}"; do
                is_preview "$parent" && continue
                preview="$(preview_slug "$parent" "$branch")"
                if is_preview "$preview" || is_provisioned "$preview"; then
                    if ! hook_run_site deploy-preview "$preview" "$PROVISIONER_DIR/provision.sh" deploy-preview "$parent" "$branch" --if-changed; then
                        failures=$((failures + 1))
                    else
                        comment_preview_pr "$provider" "$preview" "$pr" "${urls[@]}"
                    fi
                else
                    if ! hook_run_site provision-preview "$preview" "$PROVISIONER_DIR/provision.sh" provision-preview "$parent" "$branch"; then
                        failures=$((failures + 1))
                    else
                        comment_preview_pr "$provider" "$preview" "$pr" "${urls[@]}"
                    fi
                fi
            done
            ;;
        preview_remove)
            branch="${branches[0]:-}"
            [[ -n "$branch" ]] || { hook_log warn "preview_remove missing branch — dropping"; return 0; }
            for parent in "${matches[@]}"; do
                is_preview "$parent" && continue
                preview="$(preview_slug "$parent" "$branch")"
                extra=()
                if is_preview "$preview"; then
                    read_preview_meta "$preview"
                    [[ "$PREVIEW_MODE" == "isolated" ]] && extra+=(--purge-db)
                fi
                if ! hook_run_site remove-preview "$preview" "$PROVISIONER_DIR/provision.sh" remove-preview "$parent" "$branch" --purge-files "${extra[@]}"; then
                    failures=$((failures + 1))
                fi
            done
            ;;
    esac
    [[ "$failures" -eq 0 ]]
}
