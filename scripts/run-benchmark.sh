#!/bin/bash
# Run benchmark against a specific server
# Usage: ./run-benchmark.sh <server> [--scenario <name>] [--vus <n>] [--duration <time>]

set -e

cd "$(dirname "$0")/.."

# Sync local swerver sources if available
LOCAL_SWERVER_DIR="$(cd .. && pwd)/swerver"
LOCAL_SWERVER_CONTEXT="./servers/swerver/swerver-src"
if [[ -d "$LOCAL_SWERVER_DIR" ]]; then
    echo "Syncing local swerver sources..."
    rm -rf "$LOCAL_SWERVER_CONTEXT"
    mkdir -p "$LOCAL_SWERVER_CONTEXT"
    rsync -a --delete --exclude='.git' --exclude='.zig-cache' --exclude='zig-out' \
        "$LOCAL_SWERVER_DIR"/ "$LOCAL_SWERVER_CONTEXT"/
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
    swerver|nginx|httpzig|actix) ;;
    *) echo "Unknown server: $SERVER (available: swerver, nginx, httpzig, actix)"; exit 1 ;;
esac

if [[ ! -f "k6/scenarios/${SCENARIO}.js" ]]; then
    echo "Unknown scenario: $SCENARIO"
    echo "Available: throughput, latency, connections, concurrent, mixed"
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
rm -f "results/${SCENARIO}.json"

# Build
echo "Building $SERVER..."
docker-compose build "$SERVER" 2>&1 | tail -3
docker build -t "$K6_IMAGE" ./k6 2>&1 | tail -3

# Cleanup on exit
cleanup() {
    docker-compose stop "$SERVER" 2>/dev/null || true
}
trap cleanup EXIT

# Start server (creates the compose network)
echo "Starting $SERVER..."
docker-compose up -d "$SERVER" 2>/dev/null

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

docker run --rm \
    --network "$NETWORK" \
    -v "$(pwd)/results:/results" \
    -v "$(pwd)/k6/scenarios:/scenarios:ro" \
    -v "$(pwd)/k6/lib:/lib:ro" \
    -e K6_VUS="$VUS" \
    -e K6_DURATION="$DURATION" \
    -e TARGET_HOST="$SERVER" \
    -e TARGET_PORT=8080 \
    "$K6_IMAGE" \
    "/scenarios/${SCENARIO}.js" || true

# Verify and save result
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
if [[ -f "results/${SCENARIO}.json" ]]; then
    DEST="results/${SERVER}_${SCENARIO}_${TIMESTAMP}.json"
    mv "results/${SCENARIO}.json" "$DEST"
    echo ""
    echo "Results saved to: $DEST"
else
    echo ""
    echo "WARNING: No result file written"
    exit 1
fi
