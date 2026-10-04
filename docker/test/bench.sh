#!/usr/bin/env bash
# Read-path benchmark: times the `api` verbs the web UI polls against a
# fleet of N fake sites, cloned from the test suite's testsite.
#
# Needs the test containers up: `docker/test/run.sh --keep` first. Copies
# this checkout's lib/ and provision.sh into the web container before
# running, so a code change can be measured without rebuilding.
#
# Usage: docker/test/bench.sh [N ...]     default: 20 50
#        BENCH_NO_SYNC=1 docker/test/bench.sh   baseline: code as built
#        docker/test/bench.sh --clean     remove the fake sites
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE=(docker compose -p ddeploytest -f "$ROOT/docker/docker-compose.yml")

"${COMPOSE[@]}" ps --status running web >/dev/null 2>&1 \
    && "${COMPOSE[@]}" exec -T web true 2>/dev/null \
    || { echo "test containers aren't running — run 'docker/test/run.sh --keep' first" >&2; exit 1; }

# BENCH_NO_SYNC=1 measures the code the containers were built with (a
# baseline before changes); only the benchmark itself is copied in.
sync=(docker/test/bench-inside.sh)
[[ "${BENCH_NO_SYNC:-}" == 1 ]] || sync+=(lib provision.sh)
for p in "${sync[@]}"; do
    "${COMPOSE[@]}" cp "$ROOT/$p" "web:/opt/ddeploy/$(dirname "$p")/" >/dev/null
done

"${COMPOSE[@]}" exec -T -e BENCH_RUNS="${BENCH_RUNS:-7}" web bash /opt/ddeploy/docker/test/bench-inside.sh "$@"
