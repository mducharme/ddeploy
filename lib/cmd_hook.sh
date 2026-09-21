#!/usr/bin/env bash
# `hook-worker` — drain the webhook spool. Invoked by the systemd path
# unit (and by tests). Not a public operator command; argv is constructed
# here from an already-parsed internal job, never from forge JSON.

cmd_hook_worker() {
    load_conf
    require_root

    local spool="$WEBHOOK_QUEUE_ROOT/new"
    local failed="$WEBHOOK_QUEUE_ROOT/failed"
    mkdir -p "$spool" "$failed"

    local f claimed
    # Loop until empty so a job arriving while we run isn't missed if the
    # path unit only fires once per "became non-empty" edge.
    # Do not "recover" .processing-* files here: a concurrent worker
    # (systemd path unit vs an explicit hook-worker) may still be using
    # that path. A crashed claim is left for the next operator/doctor.
    while true; do
        shopt -s nullglob
        local files=("$spool"/job-*.json)
        shopt -u nullglob
        [[ "${#files[@]}" -eq 0 ]] && break
        for f in "${files[@]}"; do
            [[ -f "$f" ]] || continue
            claimed="$spool/.processing-$(basename "$f").$$.$RANDOM"
            mv "$f" "$claimed" 2>/dev/null || continue
            if ! hook_process_job "$claimed"; then
                log_error "webhook job failed: $(basename "$f")"
                mv -f "$claimed" "$failed/" || rm -f "$claimed"
            else
                rm -f "$claimed"
            fi
        done
    done
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
            log_warn "webhook: unknown event '$event' — dropping"
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
        log_info "webhook: job has no repo urls — dropping"
        return 0
    fi

    local -a matches=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && matches+=("$line")
    done < <(matching_sites_for_urls "${urls[@]}")

    if [[ "${#matches[@]}" -eq 0 ]]; then
        log_info "webhook: no provisioned site matches this repo — no-op"
        return 0
    fi

    local name branch parent preview head target hit extra failures=0
    case "$event" in
        push_head)
            for name in "${matches[@]}"; do
                is_preview "$name" && continue
                head="$(site_head_branch "$name")"
                # Also match the site's configured deploy_branch (README
                # "Default branch"), not just its current HEAD — otherwise
                # the very first push to a newly-configured branch would
                # be ignored, since HEAD only moves once deploy itself
                # performs the switch (lib/releases.sh's
                # prepare_forward_release), which this push is meant to
                # trigger in the first place.
                target="$(read_deploy_branch "$(site_dir "$name")" "$name")"
                hit=0
                for branch in "${branches[@]}"; do
                    if [[ "$head" == "$branch" ]] || [[ -n "$target" && "$target" == "$branch" ]]; then
                        hit=1; break
                    fi
                done
                if [[ "$hit" -ne 1 ]]; then
                    log_info "webhook: skipping '$name' — HEAD is '$head', push was not"
                    continue
                fi
                log_info "webhook: deploy '$name'"
                if ! with_site_lock "$name" "$PROVISIONER_DIR/provision.sh" deploy "$name"; then
                    failures=$((failures + 1))
                    notify_failure deploy "$name" "$(notify_log_snippet "$LOG_DIR/$name.log")"
                fi
            done
            ;;
        preview_upsert)
            branch="${branches[0]:-}"
            [[ -n "$branch" ]] || { log_warn "webhook: preview_upsert missing branch"; return 0; }
            for parent in "${matches[@]}"; do
                is_preview "$parent" && continue
                preview="$(preview_slug "$parent" "$branch")"
                if is_preview "$preview" || is_provisioned "$preview"; then
                    log_info "webhook: deploy-preview '$parent' '$branch'"
                    if ! with_site_lock "$preview" "$PROVISIONER_DIR/provision.sh" deploy-preview "$parent" "$branch"; then
                        failures=$((failures + 1))
                        notify_failure deploy-preview "$preview" "$(notify_log_snippet "$LOG_DIR/$preview.log")"
                    else
                        comment_preview_pr "$provider" "$preview" "$pr" "${urls[@]}"
                    fi
                else
                    log_info "webhook: provision-preview '$parent' '$branch'"
                    if ! with_site_lock "$preview" "$PROVISIONER_DIR/provision.sh" provision-preview "$parent" "$branch"; then
                        failures=$((failures + 1))
                        notify_failure provision-preview "$preview" "$(notify_log_snippet "$LOG_DIR/$preview.log")"
                    else
                        comment_preview_pr "$provider" "$preview" "$pr" "${urls[@]}"
                    fi
                fi
            done
            ;;
        preview_remove)
            branch="${branches[0]:-}"
            [[ -n "$branch" ]] || { log_warn "webhook: preview_remove missing branch"; return 0; }
            for parent in "${matches[@]}"; do
                is_preview "$parent" && continue
                preview="$(preview_slug "$parent" "$branch")"
                extra=()
                if is_preview "$preview"; then
                    read_preview_meta "$preview"
                    [[ "$PREVIEW_MODE" == "isolated" ]] && extra+=(--purge-db)
                fi
                log_info "webhook: remove-preview '$parent' '$branch'"
                if ! with_site_lock "$preview" "$PROVISIONER_DIR/provision.sh" remove-preview "$parent" "$branch" --purge-files "${extra[@]}"; then
                    failures=$((failures + 1))
                    notify_failure remove-preview "$preview" "$(notify_log_snippet "$LOG_DIR/$preview.log")"
                fi
            done
            ;;
    esac
    [[ "$failures" -eq 0 ]]
}
