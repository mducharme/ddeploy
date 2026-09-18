#!/usr/bin/env bash
# Shared helpers for docker/test/steps/*.sh — sourced, not executed
# directly. Each step script runs `set -euo pipefail` and calls `fail` to
# abort with a clear message the moment something doesn't match reality;
# this is a smoke test, not a report generator, so it stops at the first
# problem rather than collecting every failure in one run.

STEP_LOG=/var/log/ddeploy-smoke.log

step() {
    printf '\n\033[35m==> %s\033[0m\n' "$*" | tee -a "$STEP_LOG"
}

pass() {
    printf '  \033[32m[pass]\033[0m %s\n' "$*" | tee -a "$STEP_LOG"
}

fail() {
    printf '  \033[31m[FAIL]\033[0m %s\n' "$*" | tee -a "$STEP_LOG"
    exit 1
}

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc — expected to find '$needle', got: $haystack"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc — did NOT expect to find '$needle', got: $haystack"
    fi
}

assert_file_exists() {
    local f="$1" desc="${2:-file exists: $1}"
    [[ -e "$f" ]] && pass "$desc" || fail "$desc — $f not found"
}

assert_file_absent() {
    local f="$1" desc="${2:-file absent: $1}"
    [[ ! -e "$f" ]] && pass "$desc" || fail "$desc — $f still exists"
}

assert_cmd_ok() {
    local desc="$1"; shift
    if "$@" >/tmp/assert-cmd.out 2>&1; then
        pass "$desc"
    else
        fail "$desc — command failed: $* ($(cat /tmp/assert-cmd.out))"
    fi
}

assert_cmd_fails() {
    local desc="$1"; shift
    if ! "$@" >/tmp/assert-cmd.out 2>&1; then
        pass "$desc"
    else
        fail "$desc — expected command to fail but it succeeded: $*"
    fi
}

# curl's SNI (not just the Host header) is what nginx picks a vhost by
# when several server{} blocks share one cert — --resolve sets both the
# DNS answer AND the SNI/Host to $host in one go, so this reaches the
# right vhost without needing real DNS or /etc/hosts entries.
curl_site() {
    local host="$1"; shift
    curl -fsSk --resolve "${host}:443:127.0.0.1" "https://${host}/" "$@"
}
