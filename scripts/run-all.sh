#!/bin/bash
# Run all benchmark scenarios against all servers
# Usage: ./run-all.sh [--servers "swerver nginx"] [--scenarios "throughput latency"]
#
# Each server is tested in isolation (all other containers stopped).
# k6 runs via `docker run` with explicit volume mounts for reliable result collection.

set -e

cd "$(dirname "$0")/.."

# Defaults
SERVERS="${SERVERS:-swerver nginx httpzig actix apisix}"
# Soak excluded by default (5 min) — opt-in: SCENARIOS="throughput latency connections concurrent mixed spike payload keepalive rapid-fire error-handling soak"
SCENARIOS="${SCENARIOS:-throughput latency connections concurrent mixed spike payload keepalive rapid-fire error-handling}"
VUS="${K6_VUS:-100}"
DURATION="${K6_DURATION:-30s}"
RETRIES=1

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --servers)   SERVERS="$2";   shift 2 ;;
        --scenarios) SCENARIOS="$2"; shift 2 ;;
        --vus)       VUS="$2";       shift 2 ;;
        --duration)  DURATION="$2";  shift 2 ;;
        *)           echo "Unknown option: $1"; exit 1 ;;
    esac
done

K6_IMAGE="swerver-bench-k6"
RESULTS_DIR="results/run_$(date +%Y%m%d_%H%M%S)"
FAILED=0
# docker-compose network name: <project>_<network>
COMPOSE_PROJECT=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
NETWORK="${COMPOSE_PROJECT}_benchmark"

echo "========================================"
echo "Benchmark Suite"
echo "========================================"
echo "Servers:   $SERVERS"
echo "Scenarios: $SCENARIOS"
echo "VUs:       $VUS"
echo "Duration:  $DURATION"
echo "Results:   $RESULTS_DIR"
echo "========================================"
echo ""

# ---- Sync local swerver sources ----
LOCAL_SWERVER_DIR="$(cd .. && pwd)/swerver"
LOCAL_SWERVER_CONTEXT="./servers/swerver/swerver-src"
if [[ -d "$LOCAL_SWERVER_DIR" ]]; then
    echo "Syncing local swerver sources..."
    rm -rf "$LOCAL_SWERVER_CONTEXT"
    mkdir -p "$LOCAL_SWERVER_CONTEXT"
    rsync -a --delete \
        --exclude='.git' --exclude='.zig-cache' --exclude='zig-out' \
        "$LOCAL_SWERVER_DIR"/ "$LOCAL_SWERVER_CONTEXT"/
fi

# ---- Create results directory ----
mkdir -p "$RESULTS_DIR"
# Clean leftover result files
rm -f results/*.json

# ---- Build everything ----
echo "Building servers..."
docker-compose build $SERVERS 2>&1 | tail -5
echo ""
echo "Building k6..."
docker build -t "$K6_IMAGE" ./k6 2>&1 | tail -3
echo ""

# ---- Ensure clean state ----
cleanup() {
    echo ""
    echo "Cleaning up..."
    docker-compose down --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

# Stop all servers
docker-compose down --remove-orphans 2>/dev/null || true

# ---- Run a single benchmark ----
# Usage: run_benchmark <server> <scenario>
# Returns 0 if result file was saved, 1 otherwise
run_benchmark() {
    local server="$1"
    local scenario="$2"
    local result_file="results/${server}_${scenario}.json"
    local dest_file="$RESULTS_DIR/${server}_${scenario}.json"

    rm -f "$result_file"

    # Scenarios with custom executors/stages must not receive K6_VUS/K6_DURATION
    # (k6 auto-overrides options when these env vars are set)
    local env_flags="-e K6_VUS=$VUS -e K6_DURATION=$DURATION"
    case "$scenario" in
        payload|keepalive|spike|concurrent|soak) env_flags="" ;;
    esac

    # Run k6 directly via docker run — reliable volume mount
    # k6 writes to /results/{server}_{scenario}.json (server-namespaced to prevent overwrites)
    docker run --rm \
        --network "$NETWORK" \
        -v "$(pwd)/results:/results" \
        -v "$(pwd)/k6/scenarios:/scenarios:ro" \
        -v "$(pwd)/k6/lib:/lib:ro" \
        $env_flags \
        -e TARGET_HOST="$server" \
        -e TARGET_PORT=8080 \
        "$K6_IMAGE" \
        "/scenarios/${scenario}.js" 2>&1 | grep -E "^(Summary| |running \(0m(29|30))" | tail -5

    # Verify result
    if [[ ! -f "$result_file" ]]; then
        echo "  FAIL: no result file written"
        return 1
    fi

    mv "$result_file" "$dest_file"
    echo "  OK: saved to $dest_file"
    return 0
}

# ---- Wait for server to be healthy ----
wait_for_server() {
    local server="$1"
    local max_wait=30
    echo -n "  Waiting for $server..."
    for i in $(seq 1 $max_wait); do
        if docker-compose exec -T "$server" curl -sSf "http://localhost:8080/health" >/dev/null 2>&1; then
            echo " ready (${i}s)"
            return 0
        elif docker-compose exec -T "$server" wget -q --spider "http://localhost:8080/health" 2>/dev/null; then
            echo " ready (${i}s)"
            return 0
        fi
        echo -n "."
        sleep 1
    done
    echo " TIMEOUT"
    return 1
}

# ---- Main loop ----
for server in $SERVERS; do
    echo "========================================"
    echo "Testing: $server"
    echo "========================================"

    # Stop everything, start only this server
    docker-compose stop 2>/dev/null || true
    docker-compose up -d "$server" 2>/dev/null

    if ! wait_for_server "$server"; then
        echo "  SKIP: $server failed to start"
        FAILED=$((FAILED + 1))
        continue
    fi

    for scenario in $SCENARIOS; do
        echo ""
        echo "--- $server / $scenario ---"

        if ! run_benchmark "$server" "$scenario"; then
            # Retry once
            echo "  Retrying..."
            sleep 2
            if ! run_benchmark "$server" "$scenario"; then
                echo "  FAIL: $server/$scenario — giving up"
                FAILED=$((FAILED + 1))
            fi
        fi
    done

    echo ""
    docker-compose stop "$server" 2>/dev/null || true
done

# ---- Generate report ----
echo ""
echo "========================================"
RESULT_COUNT=$(ls "$RESULTS_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
echo "Results: $RESULT_COUNT files saved to $RESULTS_DIR/"

if [[ $FAILED -gt 0 ]]; then
    echo "Failures: $FAILED"
fi

if command -v python3 &>/dev/null && [[ $RESULT_COUNT -gt 0 ]]; then
    echo ""
    echo "Generating comparison report..."
    python3 ./scripts/compare-results.py "$RESULTS_DIR"/*.json > "$RESULTS_DIR/comparison.md" 2>&1
    echo "Report: $RESULTS_DIR/comparison.md"
    echo ""
    cat "$RESULTS_DIR/comparison.md"
fi
echo "========================================"
