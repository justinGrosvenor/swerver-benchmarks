#!/bin/bash
# Run the Static + API scenario
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

PROJECT="static-api"
NETWORK="${PROJECT}_default"

banner "Scenario: Static + API"
echo "  VUs:      $VUS"
echo "  Duration: $DURATION"
echo ""

mkdir -p results

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

TESTS=("static" "api" "mixed")

for TEST in "${TESTS[@]}"; do
    echo ""
    echo "Running ${TEST}..."
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
        "/scenarios/${TEST}.js" || true
done

echo ""
echo "Results:"
ls -la results/*.json 2>/dev/null || echo "  (no result files written)"
