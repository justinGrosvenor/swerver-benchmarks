#!/bin/bash
# Run the Load Balancer scenario
# Usage: ./run.sh [--vus <n>] [--duration <time>]
#
# By default the swerver Dockerfile clones SWERVER_REF (default: main).
# Set USE_LOCAL_SWERVER=1 to rsync the local working copy at ../../../swerver instead.
set -euo pipefail

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

# Sync local swerver sources (opt-in)
LOCAL_SWERVER_CONTEXT="../../servers/swerver/swerver-src"
if [[ "${USE_LOCAL_SWERVER:-0}" == "1" ]]; then
    LOCAL_SWERVER_DIR="${LOCAL_SWERVER_DIR:-$(cd ../../.. && pwd)/swerver}"
    if [[ ! -d "$LOCAL_SWERVER_DIR" ]]; then
        echo "USE_LOCAL_SWERVER=1 but LOCAL_SWERVER_DIR ($LOCAL_SWERVER_DIR) not found" >&2
        exit 1
    fi
    echo "Syncing local swerver sources from $LOCAL_SWERVER_DIR..."
    rm -rf "$LOCAL_SWERVER_CONTEXT"
    mkdir -p "$LOCAL_SWERVER_CONTEXT"
    rsync -a --delete --exclude='.git' --exclude='.zig-cache' --exclude='zig-out' \
        "$LOCAL_SWERVER_DIR"/ "$LOCAL_SWERVER_CONTEXT"/
else
    rm -rf "$LOCAL_SWERVER_CONTEXT"
fi

K6_IMAGE="grafana/k6:latest"
COMPOSE_PROJECT=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
# This scenario's compose file does not declare a custom network, so docker-compose
# creates "<project>_default".
NETWORK="${COMPOSE_PROJECT}_default"

echo "========================================"
echo "Scenario: Load Balancer"
echo "VUs:      $VUS"
echo "Duration: $DURATION"
echo "========================================"
echo ""

mkdir -p results

# Build and start
echo "Building services..."
if ! docker-compose build; then
    echo "ERROR: docker-compose build failed" >&2
    exit 1
fi
echo "Starting services..."
if ! docker-compose up -d; then
    echo "ERROR: docker-compose up failed" >&2
    exit 1
fi

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

# --- distribution test ---
echo ""
echo "Running distribution..."
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
    run "/scenarios/distribution.js" || true

# --- throughput test ---
echo ""
echo "Running throughput..."
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
    run "/scenarios/throughput.js" || true

# --- failover test ---
echo ""
echo "Running failover (pausing app-3 at 12s, unpausing at 32s)..."
echo ""

# Background process to pause/unpause app-3
(
    sleep 12
    echo "[failover] Pausing app-3..."
    docker-compose pause app-3 2>/dev/null || true
    sleep 20
    echo "[failover] Unpausing app-3..."
    docker-compose unpause app-3 2>/dev/null || true
) &
FAILOVER_PID=$!

docker run --rm \
    --network "$NETWORK" \
    -v "${SCENARIO_DIR}/results:/results" \
    -v "${SCENARIO_DIR}/k6:/scenarios:ro" \
    -v "${SCENARIO_DIR}/../../k6/lib:/lib:ro" \
    -e TARGET_HOST="swerver" \
    -e TARGET_PORT=8080 \
    "$K6_IMAGE" \
    run "/scenarios/failover.js" || true

wait "$FAILOVER_PID" 2>/dev/null || true

echo ""
echo "Results:"
ls -la results/*.json 2>/dev/null || echo "  (no result files written)"
