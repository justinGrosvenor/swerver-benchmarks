#!/bin/bash
# Run the Static + API scenario
# Usage: ./run.sh [--vus <n>] [--duration <time>]
set -e

cd "$(dirname "$0")"
SCENARIO_DIR="$(pwd)"

VUS="${K6_VUS:-100}"
DURATION="${K6_DURATION:-30s}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --vus|-v)      VUS="$2";      shift 2 ;;
        --duration|-d) DURATION="$2"; shift 2 ;;
        *)             echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Sync local swerver sources
LOCAL_SWERVER_DIR="$(cd ../.. && pwd)/../swerver"
LOCAL_SWERVER_CONTEXT="../../servers/swerver/swerver-src"
if [[ -d "$LOCAL_SWERVER_DIR" ]]; then
    echo "Syncing local swerver sources..."
    rm -rf "$LOCAL_SWERVER_CONTEXT"
    mkdir -p "$LOCAL_SWERVER_CONTEXT"
    rsync -a --delete --exclude='.git' --exclude='.zig-cache' --exclude='zig-out' \
        "$LOCAL_SWERVER_DIR"/ "$LOCAL_SWERVER_CONTEXT"/
fi

K6_IMAGE="grafana/k6:latest"
COMPOSE_PROJECT=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
NETWORK="${COMPOSE_PROJECT}_scenario"

echo "========================================"
echo "Scenario: Static + API"
echo "VUs:      $VUS"
echo "Duration: $DURATION"
echo "========================================"
echo ""

mkdir -p results

# Build and start
echo "Building services..."
docker-compose build 2>&1 | tail -5
echo "Starting services..."
docker-compose up -d

# Cleanup on exit
cleanup() {
    echo ""
    echo "Stopping services..."
    docker-compose down 2>/dev/null || true
}
trap cleanup EXIT

# Wait for swerver health
echo -n "Waiting for swerver..."
for i in $(seq 1 30); do
    if curl -sSf "http://localhost:8080/health" >/dev/null 2>&1; then
        echo " ready (${i}s)"
        break
    fi
    echo -n "."
    sleep 1
    if [[ $i -eq 30 ]]; then
        echo " TIMEOUT"
        docker-compose logs swerver
        exit 1
    fi
done

TESTS=("static" "api" "mixed")

for TEST in "${TESTS[@]}"; do
    echo ""
    echo "Running ${TEST}..."
    echo ""

    docker run --rm \
        --network "$NETWORK" \
        -v "${SCENARIO_DIR}/results:/results" \
        -v "${SCENARIO_DIR}/k6:/scenarios:ro" \
        -v "${SCENARIO_DIR}/../../k6/lib:/lib:ro" \
        -e K6_VUS="$VUS" \
        -e K6_DURATION="$DURATION" \
        -e TARGET_HOST="swerver" \
        -e TARGET_PORT=8080 \
        "$K6_IMAGE" \
        run "/scenarios/${TEST}.js" || true
done

echo ""
echo "Results:"
ls -la results/*.json 2>/dev/null || echo "  (no result files written)"
