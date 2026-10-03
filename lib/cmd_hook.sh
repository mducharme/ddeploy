#!/usr/bin/env bash
# `hook-worker` — drain the webhook spool. Invoked by the systemd path
# unit (and by tests). Not a public operator command; argv passed to
# provision.sh is constructed here from an already-verified, already-
# parsed internal job, never from forge JSON directly.
#
# Every delivery and every action it leads to gets a line in
# /var/log/ddeploy/webhook.log (`ddeploy logs webhook`), tagged with a short
# delivery id so one push's lines can be followed through: received ->
# verified/rejected/ignored -> per-site skip/deploy OK/FAILED.

# Short tag for the delivery being processed — the forge's own delivery
# id when it sent one (matches what GitHub/Bitbucket show in their
# webhook UI), else the spool file's random id.
WEBHOOK_LOG_ID=""

# Two files, because the webhook is org-wide and most deliveries are for
# repos with no site on this server:
#   webhook.log        deliveries that concern a site here (deployed,
#                      skipped, failed...), and every rejected delivery
#   webhook-other.log  one line per delivery that needed nothing from
#                      this server: no site uses the repo, or an event
#                      with nothing to do (ping, branch deletion, PR label)
# A delivery's "accepted" line is held in WEBHOOK_PENDING until it's
# known which file it belongs in: the first hook_log line flushes it to
# webhook.log ahead of itself; hook_log_other folds it into its own line.
WEBHOOK_PENDING=""
WEBHOOK_OTHER_MAX_BYTES=2000000

hook_log_write() {
    local file="$1"; shift
    mkdir -p "$LOG_DIR"
    printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${WEBHOOK_LOG_ID:--}" "$*" >> "$LOG_DIR/$file"
}

# $1 info|warn|error, rest message. To the journal and to webhook.log.
hook_log() {
    local level="$1"; shift
    case "$level" in
        warn) log_warn "webhook: $*" ;;
        error) log_error "webhook: $*" ;;
        *) log_info "webhook: $*" ;;
    esac
    if [[ -n "$WEBHOOK_PENDING" ]]; then
        hook_log_write webhook.log "$WEBHOOK_PENDING"
        WEBHOOK_PENDING=""
    fi
    hook_log_write webhook.log "$*"
}

# A delivery that needed nothing from this server: one line in
# webhook-other.log (the pending "accepted" line, if any, prefixed to
# it). Trimmed to its newest half once it passes ~2 MB — it's the
# high-volume one, and nothing in it is worth keeping for long.
hook_log_other() {
    log_info "webhook: ${WEBHOOK_PENDING:+$WEBHOOK_PENDING — }$*"
    hook_log_write webhook-other.log "${WEBHOOK_PENDING:+$WEBHOOK_PENDING — }$*"
    WEBHOOK_PENDING=""
    local f="$LOG_DIR/webhook-other.log" size
    size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    if [[ "$size" -gt "$WEBHOOK_OTHER_MAX_BYTES" ]]; then
        local tmp; tmp="$(mktemp)"
        tail -c "$((WEBHOOK_OTHER_MAX_BYTES / 2))" "$f" | tail -n +2 > "$tmp"
        cat "$tmp" > "$f"
        rm -f "$tmp"
    fi
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

    WEBHOOK_PENDING=""
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
            notify_event webhook-rejected "" "Webhook rejected" "${summary}: signature doesn't match the webhook secret — check the secret in the forge's webhook settings" cooldown
            rm -f "$claimed"
            return
            ;;
        1)
            # Default set outside the "${...}": an apostrophe inside a
            # double-quoted ${var:-word} is a quote character to bash.
            [[ -n "$reason" ]] || reason="could not verify/parse the request"
            hook_log warn "$summary -> REJECTED: $reason — dropped"
            notify_event webhook-rejected "" "Webhook rejected" "${summary}: $reason" cooldown
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
        hook_log_other "$summary -> ignored: ${reason:-nothing to do}"
        rm -f "$claimed"
        return
    fi
    WEBHOOK_PENDING="$summary -> accepted: $reason"

    local job_file="$claimed.job"
    printf '%s' "$report" | yq -p=json -o=json -I=0 eval '.job' - > "$job_file"
    # Seen by every provision.sh this job runs, for their own logs, Slack
    # messages and run history ("webhook [id] by <who pushed>"). The actor
    # is already log-safe (verify_and_spool.py _clean); the charset check
    # here is belt-and-braces before it becomes part of every event line.
    local actor; actor="$(hook_report_field "$report" '.meta.actor')"
    [[ "$actor" =~ ^[A-Za-z0-9._@+-]{1,100}$ ]] || actor=""
    export DDEPLOY_TRIGGER="webhook [$WEBHOOK_LOG_ID]${actor:+ by $actor}"
    if ! hook_process_job "$job_file"; then
        hook_log error "job failed — kept at $failed/$(basename "$job_file") for inspection"
        mv -f "$job_file" "$failed/" || rm -f "$job_file"
    else
        rm -f "$job_file"
    fi
    unset DDEPLOY_TRIGGER
    # Every path above logs something, which flushes the held "accepted"
    # line; this only catches one that somehow didn't.
    if [[ -n "$WEBHOOK_PENDING" ]]; then
        hook_log_write webhook.log "$WEBHOOK_PENDING"
        WEBHOOK_PENDING=""
    fi
    rm -f "$claimed"
}

# $1 label (deploy, deploy-preview, ...) $2 site, rest the command to
# run under that site's lock. Logs start and outcome (with the new sha
# and duration, or the tail of the site's own log on failure) to
# webhook.log. Failure notifications come from the provision.sh
# subprocess itself (see run_notifying in provision.sh), not here.
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
        hook_log error "$label $site: FAILED (exit $rc, ${took}s) — $(notify_log_snippet "$LOG_DIR/$site.log") — full log: ddeploy logs $site"
    fi
    return "$rc"
}

# $1 site — its preview_branches patterns, one per line: from the first
# of the operator override, .ddeploy/config.yaml, .ddev/config.yaml (or
# sidecar) that has the key at all — an explicit empty list there means
# "off for this site" — else the server-wide PREVIEW_BRANCHES. Read
# straight from the files, not via parse_config, which writes the site's
# steps file as a side effect.
read_preview_branch_patterns() {
    local name="$1" p f src=""
    for f in "$(override_config_path "$name")" "$(ext_config_path "$name")" "$(resolve_config_path "$name")"; do
        [[ -n "$f" && -f "$f" ]] || continue
        if [[ "$(yq eval 'has("preview_branches")' "$f" 2>/dev/null)" == "true" ]]; then
            src="$f"
            break
        fi
    done
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if [[ "$p" =~ ^[A-Za-z0-9._/*?@+-]+$ ]]; then
            printf '%s\n' "$p"
        else
            log_warn "webhook: $name: ignoring preview_branches entry '$p' — not a branch pattern"
        fi
    done < <(
        if [[ -n "$src" ]]; then
            yq eval '.preview_branches[]' "$src" 2>/dev/null | grep -vx 'null' || true
        else
            # Word-split on purpose: a space-separated list in provisioner.conf.
            # set -f: the patterns are globs, not for the filesystem.
            ( set -f; for p in ${PREVIEW_BRANCHES:-}; do printf '%s\n' "$p"; done )
        fi
    )
}

# $1 branch, rest glob patterns. `*` matches across '/', so `*` is every
# branch and `feature/*` is feature/a and feature/a/b alike.
branch_matches_any() {
    local branch="$1" p; shift
    for p in "$@"; do
        # shellcheck disable=SC2053  # unquoted on purpose: a glob
        [[ "$branch" == $p ]] && return 0
    done
    return 1
}

# Creates or updates $1's preview of branch $2. $3 provider, $4 PR
# number (empty for a branch-pattern preview: no PR to comment on), rest
# the job's repo URLs. Returns nonzero if the deploy failed.
hook_upsert_preview() {
    local parent="$1" branch="$2" provider="$3" pr="$4"; shift 4
    local preview; preview="$(preview_slug "$parent" "$branch")"
    # A name taken by something else (see assert_preview_of): say so
    # plainly instead of failing inside provision.sh.
    if ! (assert_preview_of "$preview" "$parent" "preview") 2>/dev/null; then
        hook_log warn "skip $preview: that name is already a regular site or another project's preview — branch '$branch' can't get a preview of $parent (rename the branch)"
        return 0
    fi
    local cmd=provision-preview
    local -a extra=()
    if is_preview "$preview" || is_provisioned "$preview"; then
        cmd=deploy-preview
        extra=(--if-changed)
    fi
    hook_run_site "$cmd" "$preview" "$PROVISIONER_DIR/provision.sh" "$cmd" "$parent" "$branch" "${extra[@]}" || return 1
    if [[ -n "$pr" ]]; then
        comment_preview_pr "$provider" "$preview" "$pr" "$@"
    fi
}

# Removes $1's preview of branch $2, if it has one. $3 why (for the log).
hook_remove_preview() {
    local parent="$1" branch="$2" why="$3"
    local preview; preview="$(preview_slug "$parent" "$branch")"
    # Only ever this project's own preview — never a regular site (or
    # another project's preview) that happens to have the same name, and
    # nothing to do when there never was one.
    if ! is_preview "$preview"; then
        # A deleted branch usually never had a preview: not worth a line
        # in the main log. A closed PR without one is worth noting there.
        if [[ "$why" == "branch deleted" ]]; then
            hook_log_other "no preview of $parent for deleted branch '$branch' — nothing to remove"
        else
            hook_log info "skip $preview: no preview of $parent for branch '$branch' to remove ($why)"
        fi
        return 0
    fi
    if ! (assert_preview_of "$preview" "$parent" "remove") 2>/dev/null; then
        hook_log warn "skip $preview: it's another project's preview, not $parent's — not removing it"
        return 0
    fi
    local -a extra=()
    read_preview_meta "$preview"
    [[ "$PREVIEW_MODE" == "isolated" ]] && extra+=(--purge-db)
    hook_run_site remove-preview "$preview" "$PROVISIONER_DIR/provision.sh" remove-preview "$parent" "$branch" --purge-files "${extra[@]}"
}

# Reads one job file, maps event → existing CLI. Returns nonzero if any
# invoked command failed; unknown remotes are success (org hooks).
hook_process_job() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    require_yq
    local event branches_raw deleted_raw urls_raw provider pr
    event="$(yq eval '.event // ""' "$f")"
    provider="$(yq eval '.provider // ""' "$f")"
    pr="$(yq eval '.pr // ""' "$f")"
    [[ "$pr" == "null" ]] && pr=""
    branches_raw="$(yq eval '.branches[]' "$f" 2>/dev/null | grep -vx 'null' || true)"
    deleted_raw="$(yq eval '.deleted_branches[]' "$f" 2>/dev/null | grep -vx 'null' || true)"
    urls_raw="$(yq eval '.repo_urls[]' "$f" 2>/dev/null | grep -vx 'null' || true)"

    case "$event" in
        push_head|preview_upsert|preview_remove) ;;
        *)
            hook_log warn "unknown event '$event' — dropping"
            return 0
            ;;
    esac

    local -a branches=() deleted=() urls=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && branches+=("$line")
    done <<< "$branches_raw"
    while IFS= read -r line; do
        [[ -n "$line" ]] && deleted+=("$line")
    done <<< "$deleted_raw"
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
        hook_log_other "no site on this server uses ${urls[0]}"
        return 0
    fi

    local name branch parent head target hit failures=0
    case "$event" in
        push_head)
            # Every branch a site from this repo deploys: those never get
            # a branch preview, whatever preview_branches says (`*` would
            # otherwise give `develop` a preview of the site tracking
            # `main`, duplicating the site that tracks `develop`).
            local -a tracked=()
            for name in "${matches[@]}"; do
                is_preview "$name" && continue
                tracked+=("$(site_head_branch "$name")")
                target="$(read_deploy_branch "$name")"
                [[ -n "$target" ]] && tracked+=("$target")
            done

            for name in "${matches[@]}"; do
                is_preview "$name" && continue
                [[ "${#branches[@]}" -gt 0 ]] || continue
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

            # Branch previews without a PR, for sites that opt in with
            # preview_branches (README "Branch previews").
            local -a patterns=()
            for parent in "${matches[@]}"; do
                is_preview "$parent" && continue
                mapfile -t patterns < <(read_preview_branch_patterns "$parent")
                [[ "${#patterns[@]}" -gt 0 ]] || continue
                for branch in "${branches[@]}"; do
                    branch_matches_any "$branch" "${tracked[@]}" && continue
                    branch_matches_any "$branch" "${patterns[@]}" || continue
                    hook_upsert_preview "$parent" "$branch" "$provider" "" "${urls[@]}" || failures=$((failures + 1))
                done
            done

            # A deleted branch takes its preview with it, however the
            # preview was made (PR, branch pattern, by hand) — it can't
            # be deployed any more. Same as prune-previews, just sooner.
            for branch in "${deleted[@]}"; do
                for parent in "${matches[@]}"; do
                    is_preview "$parent" && continue
                    hook_remove_preview "$parent" "$branch" "branch deleted" || failures=$((failures + 1))
                done
            done
            ;;
        preview_upsert)
            branch="${branches[0]:-}"
            [[ -n "$branch" ]] || { hook_log warn "preview_upsert missing branch — dropping"; return 0; }
            for parent in "${matches[@]}"; do
                is_preview "$parent" && continue
                hook_upsert_preview "$parent" "$branch" "$provider" "$pr" "${urls[@]}" || failures=$((failures + 1))
            done
            ;;
        preview_remove)
            branch="${branches[0]:-}"
            [[ -n "$branch" ]] || { hook_log warn "preview_remove missing branch — dropping"; return 0; }
            for parent in "${matches[@]}"; do
                is_preview "$parent" && continue
                hook_remove_preview "$parent" "$branch" "PR closed" || failures=$((failures + 1))
            done
            ;;
    esac
    [[ "$failures" -eq 0 ]]
}
