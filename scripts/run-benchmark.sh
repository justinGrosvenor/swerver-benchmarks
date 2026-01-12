#!/bin/bash
# Run benchmark against a specific server
# Usage: ./run-benchmark.sh <server> [--scenario <name>] [--vus <n>] [--duration <time>]

set -e

# Provide local swerver sources to the Docker build context when available.
LOCAL_SWERVER_DIR="$(cd .. && pwd)/swerver"
LOCAL_SWERVER_CONTEXT="./servers/swerver/swerver-src"
if [[ -d "$LOCAL_SWERVER_DIR" ]]; then
    echo "Syncing local swerver sources into Docker context..."
    rm -rf "$LOCAL_SWERVER_CONTEXT"
    mkdir -p "$LOCAL_SWERVER_CONTEXT"
    rsync -a --delete --exclude='.git' "$LOCAL_SWERVER_DIR"/ "$LOCAL_SWERVER_CONTEXT"/
else
    echo "Local swerver source not found at $LOCAL_SWERVER_DIR; build will clone from origin."
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
        --scenario|-s)
            SCENARIO="$2"
            shift 2
            ;;
        --vus|-v)
            VUS="$2"
            shift 2
            ;;
        --duration|-d)
            DURATION="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate server
case $SERVER in
    swerver|nginx|httpzig|actix)
        TARGET_PORT=8080
        ;;
    *)
        echo "Unknown server: $SERVER"
        echo "Available: swerver, nginx, httpzig, actix"
        exit 1
        ;;
esac

# Validate scenario
if [[ ! -f "k6/scenarios/${SCENARIO}.js" ]]; then
    echo "Unknown scenario: $SCENARIO"
    echo "Available: throughput, latency, connections, concurrent, mixed"
    exit 1
fi

echo "========================================"
echo "Benchmark Configuration"
echo "========================================"
echo "Server:   $SERVER"
echo "Scenario: $SCENARIO"
echo "VUs:      $VUS"
echo "Duration: $DURATION"
echo "========================================"
echo ""
if [[ "$SCENARIO" == "concurrent" ]]; then
    echo "Note: concurrent scenario ignores --duration/K6_DURATION; using fixed ramp stages."
    echo ""
fi

# Ensure results directory exists
mkdir -p results

# Build and start the target server
echo "Starting $SERVER..."
docker-compose up -d --build "$SERVER"

# Wait for health check
echo "Waiting for $SERVER to be ready..."
for i in {1..30}; do
    if docker-compose exec -T "$SERVER" curl -sSf "http://localhost:8080/health" >/dev/null 2>&1; then
        echo "$SERVER is ready!"
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "Timeout waiting for $SERVER"
        docker-compose logs "$SERVER"
        exit 1
    fi
    sleep 1
done

# Run benchmark
echo ""
echo "Running $SCENARIO benchmark..."
echo ""

set +e
docker-compose run --rm \
    -e K6_VUS="$VUS" \
    -e K6_DURATION="$DURATION" \
    -e TARGET_HOST="$SERVER" \
    -e TARGET_PORT="$TARGET_PORT" \
    k6 "/scenarios/${SCENARIO}.js"
K6_EXIT=$?
set -e
if [[ $K6_EXIT -ne 0 ]]; then
    echo "k6 exited with status $K6_EXIT; preserving any results."
fi

# Copy results with server name prefix
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
if [[ -f "results/${SCENARIO}.json" ]]; then
    mv "results/${SCENARIO}.json" "results/${SERVER}_${SCENARIO}_${TIMESTAMP}.json"
    echo ""
    echo "Results saved to: results/${SERVER}_${SCENARIO}_${TIMESTAMP}.json"
fi

echo ""
echo "Benchmark complete!"
