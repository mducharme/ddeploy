#!/usr/bin/env bash
# Runs inside the web test container (see docker/test/bench.sh). Clones
# testsite into bench1..benchN (every fifth one a shared-mode preview of
# testsite instead), then times the api read verbs and counts the
# processes each one starts.
set -euo pipefail
cd /opt/ddeploy

# The same libraries, in the same order, as provision.sh.
LIB_DIR=/opt/ddeploy/lib
while read -r f; do
    # shellcheck source=/dev/null
    source "$LIB_DIR/$f"
done < <(sed -n 's|^source "\$LIB_DIR/\(.*\)"$|\1|p' provision.sh)
load_conf

RUNS="${BENCH_RUNS:-7}"
BENCH_RE='^bench[0-9]+(-feature)?$'

bench_names() {
    local f n
    for f in /etc/nginx/sites-available/bench*.conf; do
        [[ -f "$f" ]] || continue
        n="$(basename "$f" .conf)"
        [[ "$n" =~ $BENCH_RE ]] && printf '%s\n' "$n"
    done
    return 0
}

clean() {
    local n
    for n in $(bench_names); do
        rm -rf "${SITES_ROOT:?}/$n" "/etc/nginx/sites-available/$n.conf" \
            "$GENERATED_DIR/$n.yaml" "$GENERATED_DIR/$n.override.yaml" "$GENERATED_DIR/$n.preview" \
            "$EVENTS_DIR/$n.jsonl"
    done
    rm -rf "$DDEPLOY_STATE/index"
}

# testsite's live config: inside the checkout (.ddev/config.yaml) or the
# sidecar. Each clone gets its own copy with its own name.
make_site() {
    local n="$1" src_root="$SITES_ROOT/testsite"
    cp -a "$src_root" "$SITES_ROOT/$n"
    # current -> the clone's own copy of the live release, not testsite's.
    local rel; rel="$(basename "$(readlink -f "$src_root/current")")"
    ln -sfn "$SITES_ROOT/$n/releases/$rel" "$SITES_ROOT/$n/current"
    local cfg="$SITES_ROOT/$n/releases/$rel/.ddev/config.yaml"
    if [[ -f "$cfg" ]]; then
        sed -i "s/^name: .*/name: $n/" "$cfg"
    elif [[ -f "$GENERATED_DIR/testsite.yaml" ]]; then
        sed "s/^name: .*/name: $n/" "$GENERATED_DIR/testsite.yaml" > "$GENERATED_DIR/$n.yaml"
    fi
    [[ -f "$GENERATED_DIR/testsite.override.yaml" ]] && cp "$GENERATED_DIR/testsite.override.yaml" "$GENERATED_DIR/$n.override.yaml"
    cp /etc/nginx/sites-available/testsite.conf "/etc/nginx/sites-available/$n.conf"
    [[ -f "$EVENTS_DIR/testsite.jsonl" ]] && sed "s/\"site\":\"testsite\"/\"site\":\"$n\"/" "$EVENTS_DIR/testsite.jsonl" > "$EVENTS_DIR/$n.jsonl"
    return 0
}

# A shared-mode preview of testsite: in-place checkout, no releases.
make_preview() {
    local n="$1"
    mkdir -p "$SITES_ROOT/$n"
    cp -a "$(readlink -f "$SITES_ROOT/testsite/current")/." "$SITES_ROOT/$n/"
    cat > "$GENERATED_DIR/$n.preview" <<EOF
PROJECT=testsite
BRANCH=feature
MODE=shared
EOF
    cp /etc/nginx/sites-available/testsite.conf "/etc/nginx/sites-available/$n.conf"
}

# The clones' source: the suite's testsite, provisioned again from the
# fixture repo if the suite removed it, plus a few events so each clone
# has history to read.
SEED_REPO="ssh://gitfixture@127.0.0.1/srv/git/testsite.git"
ensure_seed() {
    is_provisioned testsite && return 0
    echo "provisioning testsite (seed for the clones)..."
    ./provision.sh provision testsite "$SEED_REPO" >/dev/null 2>&1
    local i
    for ((i = 0; i < 3; i++)); do ./provision.sh deploy testsite >/dev/null 2>&1 || true; done
}

setup() {
    local want="$1" have i
    have="$(bench_names | wc -l)"
    [[ "$have" -eq "$want" ]] && return 0
    ensure_seed
    clean
    for ((i = 1; i <= want; i++)); do
        if (( i % 5 == 0 )); then make_preview "bench$i-feature"; else make_site "bench$i"; fi
    done
}

# Median and p95 of $RUNS timings (ms) of "$@".
timeit() {
    local -a t=()
    local i s e
    for ((i = 0; i < RUNS; i++)); do
        s="$(date +%s%N)"
        "$@" >/dev/null 2>&1 || true
        e="$(date +%s%N)"
        t+=($(( (e - s) / 1000000 )))
    done
    mapfile -t t < <(printf '%s\n' "${t[@]}" | sort -n)
    local p95=$(( (RUNS * 95 + 99) / 100 - 1 ))
    printf '%6s ms  %6s ms' "${t[RUNS / 2]}" "${t[p95]}"
}

# Processes started by one run of "$@" (execve calls, children included).
procs() {
    if command -v strace >/dev/null 2>&1; then
        strace -f -qq -e trace=execve -o /tmp/bench.strace "$@" >/dev/null 2>&1 || true
        grep -c 'execve(' /tmp/bench.strace
    else
        echo "?"
    fi
}

row() {
    local label="$1"; shift
    printf '  %-28s %s  %6s\n' "$label" "$(timeit "$@")" "$(procs "$@")"
}

bench() {
    local n="$1"
    setup "$n"
    local -a names=()
    mapfile -t names < <(bench_names)
    local one="${names[0]}"
    printf '\n%d sites (+ testsite), %d runs each\n' "$n" "$RUNS"
    printf '  %-28s %9s  %9s  %6s\n' verb median p95 procs
    row "api sites"            ./provision.sh api sites
    row "api site-names"       ./provision.sh api site-names
    row "api site $one"        ./provision.sh api site "$one"
    row "api events"           ./provision.sh api events
    row "api events --site"    ./provision.sh api events --site "$one"
    row "api doctor"           ./provision.sh api doctor
    row "list"                 ./provision.sh list
}

if [[ "${1:-}" == "--clean" ]]; then
    clean
    echo "bench sites removed"
    exit 0
fi

command -v strace >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq strace >/dev/null 2>&1 || true

[[ $# -gt 0 ]] || set -- 20 50
for n in "$@"; do bench "$n"; done
