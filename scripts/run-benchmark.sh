#!/bin/bash
# Run benchmark against a specific server
# Usage: ./run-benchmark.sh <server> [--scenario <name>] [--vus <n>] [--duration <time>]
#
# By default the swerver Dockerfile clones SWERVER_REF (default: main) so numbers
# are reproducible across machines. Set USE_LOCAL_SWERVER=1 to rsync the local
# working copy at ../swerver into the build context instead.

set -euo pipefail

cd "$(dirname "$0")/.."

# Sync local swerver sources (opt-in)
LOCAL_SWERVER_CONTEXT="./servers/swerver/swerver-src"
if [[ "${USE_LOCAL_SWERVER:-0}" == "1" ]]; then
    LOCAL_SWERVER_DIR="${LOCAL_SWERVER_DIR:-$(cd .. && pwd)/swerver}"
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

# Defaults
SERVER="${1:-swerver}"
SCENARIO="throughput"
VUS="${K6_VUS:-100}"
DURATION="${K6_DURATION:-30s}"

# Parse args
shift || true
while [[ $# -gt 0 ]]; do
    case $1 in
        --scenario|-s) SCENARIO="$2"; shift 2 ;;
        --vus|-v)      VUS="$2";      shift 2 ;;
        --duration|-d) DURATION="$2"; shift 2 ;;
        *)             echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate
case $SERVER in
    swerver|nginx|httpzig|actix|apisix) ;;
    *) echo "Unknown server: $SERVER (available: swerver, nginx, httpzig, actix, apisix)"; exit 1 ;;
esac

if [[ ! -f "k6/scenarios/${SCENARIO}.js" ]]; then
    echo "Unknown scenario: $SCENARIO"
    echo "Available: throughput, latency, connections, concurrent, mixed, spike, payload, keepalive, rapid-fire, error-handling, soak"
    exit 1
fi

K6_IMAGE="swerver-bench-k6"
COMPOSE_PROJECT=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
NETWORK="${COMPOSE_PROJECT}_benchmark"

echo "========================================"
echo "Server:   $SERVER"
echo "Scenario: $SCENARIO"
echo "VUs:      $VUS"
echo "Duration: $DURATION"
echo "========================================"
echo ""

mkdir -p results
rm -f "results/${SERVER}_${SCENARIO}.json"

# Build
echo "Building $SERVER..."
if ! docker-compose build "$SERVER"; then
    echo "ERROR: docker-compose build failed for $SERVER" >&2
    exit 1
fi
if ! docker build -t "$K6_IMAGE" ./k6; then
    echo "ERROR: k6 image build failed" >&2
    exit 1
fi

# Cleanup on exit
cleanup() {
    docker-compose stop "$SERVER" 2>/dev/null || true
}
trap cleanup EXIT

# Start server (creates the compose network)
echo "Starting $SERVER..."
if ! docker-compose up -d "$SERVER"; then
    echo "ERROR: failed to start $SERVER" >&2
    exit 1
fi

# Wait for healthy
echo -n "Waiting..."
for i in $(seq 1 30); do
    if docker-compose exec -T "$SERVER" curl -sSf "http://localhost:8080/health" >/dev/null 2>&1; then
        echo " ready (${i}s)"
        break
    elif docker-compose exec -T "$SERVER" wget -q --spider "http://localhost:8080/health" 2>/dev/null; then
        echo " ready (${i}s)"
        break
    fi
    echo -n "."
    sleep 1
    if [[ $i -eq 30 ]]; then
        echo " TIMEOUT"
        docker-compose logs "$SERVER"
        exit 1
    fi
done

# Run k6 via docker run
echo ""
echo "Running $SCENARIO..."
echo ""

# Scenarios with custom executors/stages must not receive K6_VUS/K6_DURATION
ENV_FLAGS="-e K6_VUS=$VUS -e K6_DURATION=$DURATION"
case "$SCENARIO" in
    payload|keepalive|spike|concurrent|soak) ENV_FLAGS="" ;;
esac

K6_EXIT=0
docker run --rm \
    --network "$NETWORK" \
    -v "$(pwd)/results:/results" \
    -v "$(pwd)/k6/scenarios:/scenarios:ro" \
    -v "$(pwd)/k6/lib:/lib:ro" \
    $ENV_FLAGS \
    -e TARGET_HOST="$SERVER" \
    -e TARGET_PORT=8080 \
    "$K6_IMAGE" \
    "/scenarios/${SCENARIO}.js" || K6_EXIT=$?

if [[ $K6_EXIT -ne 0 ]]; then
    echo "WARNING: k6 exited with status $K6_EXIT (thresholds may have failed)"
fi

# Verify and save result
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
if [[ -f "results/${SERVER}_${SCENARIO}.json" ]]; then
    DEST="results/${SERVER}_${SCENARIO}_${TIMESTAMP}.json"
    mv "results/${SERVER}_${SCENARIO}.json" "$DEST"
    echo ""
    echo "Results saved to: $DEST"
else
    echo ""
    echo "WARNING: No result file written"
    exit 1
fi
