#!/bin/bash
# Run the Load Balancer scenario
# Usage: ./run.sh [--vus <n>] [--duration <time>]
#
# Set USE_LOCAL_SWERVER=1 to rsync the local working copy instead of cloning.
set -euo pipefail

cd "$(dirname "$0")"
SCENARIO_DIR="$(pwd)"
BENCH_ROOT="$(cd ../.. && pwd)"
source "$BENCH_ROOT/lib/common.sh"

VUS="${K6_VUS:-100}"
DURATION="${K6_DURATION:-30s}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --vus|-v)      VUS="$2";      shift 2 ;;
        --duration|-d) DURATION="$2"; shift 2 ;;
        *)             echo "Unknown option: $1"; exit 1 ;;
    esac
done

sync_swerver

ensure_k6_image
PROJECT="load-balancer"
NETWORK="${PROJECT}_default"

banner "Scenario: Load Balancer"
echo "  VUs:      $VUS"
echo "  Duration: $DURATION"
echo ""

mkdir -p results

# Build and start
echo "Building services..."
dc "$SCENARIO_DIR" "$PROJECT" build 2>&1 | tail -3
echo "Starting services..."
dc "$SCENARIO_DIR" "$PROJECT" up -d

cleanup() {
    echo ""
    echo "Stopping services..."
    dc "$SCENARIO_DIR" "$PROJECT" down 2>/dev/null || true
}
trap cleanup EXIT

wait_healthy "$SCENARIO_DIR" "$PROJECT" "swerver" "curl -sSf http://localhost:8080/health" 30

run_k6_test() {
    local test="$1"
    echo ""
    echo "Running ${test}..."
    echo ""
    docker run --rm \
        --network "$NETWORK" \
        -v "$SCENARIO_DIR/results:/results" \
        -v "$SCENARIO_DIR/k6:/scenarios:ro" \
        -v "$BENCH_ROOT/k6/lib:/lib:ro" \
        -e "K6_VUS=$VUS" \
        -e "K6_DURATION=$DURATION" \
        -e TARGET_HOST=swerver \
        -e TARGET_PORT=8080 \
        "$K6_IMAGE" \
        "/scenarios/${test}.js" || true
}

run_k6_test distribution
run_k6_test throughput

# Failover: pause/unpause app-3 during test
echo ""
echo "Running failover (pausing app-3 at 12s, unpausing at 32s)..."
echo ""
(
    sleep 12
    echo "[failover] Pausing app-3..."
    dc "$SCENARIO_DIR" "$PROJECT" pause app-3 2>/dev/null || true
    sleep 20
    echo "[failover] Unpausing app-3..."
    dc "$SCENARIO_DIR" "$PROJECT" unpause app-3 2>/dev/null || true
) &
FAILOVER_PID=$!

docker run --rm \
    --network "$NETWORK" \
    -v "$SCENARIO_DIR/results:/results" \
    -v "$SCENARIO_DIR/k6:/scenarios:ro" \
    -v "$BENCH_ROOT/k6/lib:/lib:ro" \
    -e TARGET_HOST=swerver \
    -e TARGET_PORT=8080 \
    "$K6_IMAGE" \
    "/scenarios/failover.js" || true

wait "$FAILOVER_PID" 2>/dev/null || true

echo ""
echo "Results:"
ls -la results/*.json 2>/dev/null || echo "  (no result files written)"
