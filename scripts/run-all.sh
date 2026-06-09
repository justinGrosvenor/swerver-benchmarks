#!/bin/bash
# Run all H1 benchmark scenarios against all servers
# Usage: ./run-all.sh [--servers "swerver nginx"] [--scenarios "throughput latency"]
#
# Each server is tested in isolation (all other containers stopped).
# k6 runs via `docker run` with explicit volume mounts for reliable result collection.
#
# Set USE_LOCAL_SWERVER=1 to rsync local working copy instead of git clone.

set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$BENCH_ROOT/lib/common.sh"

# Defaults
SERVERS="${SERVERS:-swerver nginx httpzig actix apisix}"
# Soak excluded by default (5 min)
SCENARIOS="${SCENARIOS:-throughput latency connections concurrent mixed spike payload keepalive rapid-fire error-handling}"
VUS="${K6_VUS:-100}"
DURATION="${K6_DURATION:-30s}"
RETRIES=1

while [[ $# -gt 0 ]]; do
    case $1 in
        --servers)   SERVERS="$2";   shift 2 ;;
        --scenarios) SCENARIOS="$2"; shift 2 ;;
        --vus)       VUS="$2";       shift 2 ;;
        --duration)  DURATION="$2";  shift 2 ;;
        *)           echo "Unknown option: $1"; exit 1 ;;
    esac
done

ensure_k6_image
RESULTS_DIR="$BENCH_ROOT/results/run_$(date +%Y%m%d_%H%M%S)"
FAILED=0
PROJECT=$(basename "$BENCH_ROOT" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
NETWORK="${PROJECT}_benchmark"

banner "Benchmark Suite"
echo "  Servers:   $SERVERS"
echo "  Scenarios: $SCENARIOS"
echo "  VUs:       $VUS"
echo "  Duration:  $DURATION"
echo "  Results:   $RESULTS_DIR"
echo ""

sync_swerver

mkdir -p "$RESULTS_DIR"
find "$BENCH_ROOT/results" -maxdepth 1 -name "*.json" -delete 2>/dev/null || true

echo "Building servers..."
(cd "$BENCH_ROOT" && docker-compose build $SERVERS) || { echo "ERROR: build failed" >&2; exit 1; }
echo ""

cleanup() {
    echo ""
    echo "Cleaning up..."
    (cd "$BENCH_ROOT" && docker-compose down --remove-orphans 2>/dev/null || true)
}
trap cleanup EXIT

(cd "$BENCH_ROOT" && docker-compose down --remove-orphans 2>/dev/null || true)

run_benchmark() {
    local server="$1" scenario="$2"
    local result_file="$BENCH_ROOT/results/${server}_${scenario}.json"
    local dest_file="$RESULTS_DIR/${server}_${scenario}.json"

    rm -f "$result_file"

    local env_flags="-e K6_VUS=$VUS -e K6_DURATION=$DURATION"
    case "$scenario" in
        payload|keepalive|spike|concurrent|soak) env_flags="" ;;
    esac

    set +e
    docker run --rm \
        --network "$NETWORK" \
        -v "$BENCH_ROOT/results:/results" \
        -v "$BENCH_ROOT/k6/scenarios:/scenarios:ro" \
        -v "$BENCH_ROOT/k6/lib:/lib:ro" \
        $env_flags \
        -e TARGET_HOST="$server" \
        -e TARGET_PORT=8080 \
        "$K6_IMAGE" \
        "/scenarios/${scenario}.js" 2>&1 | grep -E "^(Summary| |running \(0m(29|30))" | tail -5
    set -e

    if [[ ! -f "$result_file" ]]; then
        echo "  FAIL: no result file written"
        return 1
    fi

    mv "$result_file" "$dest_file"
    echo "  OK: saved to $dest_file"
    return 0
}

wait_for_server() {
    local server="$1"
    echo -n "  Waiting for $server..."
    for i in $(seq 1 30); do
        if (cd "$BENCH_ROOT" && docker-compose exec -T "$server" curl -sSf "http://localhost:8080/health" >/dev/null 2>&1); then
            echo " ready (${i}s)"
            return 0
        elif (cd "$BENCH_ROOT" && docker-compose exec -T "$server" wget -q --spider "http://localhost:8080/health" 2>/dev/null); then
            echo " ready (${i}s)"
            return 0
        fi
        echo -n "."
        sleep 1
    done
    echo " TIMEOUT"
    return 1
}

for server in $SERVERS; do
    banner "Testing: $server"

    (cd "$BENCH_ROOT" && docker-compose stop 2>/dev/null || true)
    if ! (cd "$BENCH_ROOT" && docker-compose up -d "$server"); then
        echo "  SKIP: $server failed to start"
        FAILED=$((FAILED + 1))
        continue
    fi

    if ! wait_for_server "$server"; then
        echo "  SKIP: $server failed to start"
        (cd "$BENCH_ROOT" && docker-compose logs "$server" 2>&1 | tail -20)
        FAILED=$((FAILED + 1))
        continue
    fi

    for scenario in $SCENARIOS; do
        echo ""
        echo "--- $server / $scenario ---"

        if ! run_benchmark "$server" "$scenario"; then
            echo "  Retrying..."
            sleep 2
            if ! run_benchmark "$server" "$scenario"; then
                echo "  FAIL: $server/$scenario — giving up"
                FAILED=$((FAILED + 1))
            fi
        fi
    done

    echo ""
    (cd "$BENCH_ROOT" && docker-compose stop "$server" 2>/dev/null || true)
done

echo ""
banner "Summary"
RESULT_COUNT=$(ls "$RESULTS_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
echo "  Results: $RESULT_COUNT files in $RESULTS_DIR/"
[[ $FAILED -gt 0 ]] && echo "  Failures: $FAILED"

if command -v python3 &>/dev/null && [[ $RESULT_COUNT -gt 0 ]]; then
    echo ""
    echo "Generating comparison report..."
    python3 "$BENCH_ROOT/scripts/compare-results.py" "$RESULTS_DIR"/*.json > "$RESULTS_DIR/comparison.md" 2>&1 || true
    if [[ -s "$RESULTS_DIR/comparison.md" ]]; then
        echo "Report: $RESULTS_DIR/comparison.md"
        echo ""
        cat "$RESULTS_DIR/comparison.md"
    fi
fi
