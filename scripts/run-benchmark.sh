#!/bin/bash
# Run benchmark against a specific server
# Usage: ./run-benchmark.sh <server> [--scenario <name>] [--vus <n>] [--duration <time>]
#
# Set USE_LOCAL_SWERVER=1 to rsync the local working copy.

set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$BENCH_ROOT/lib/common.sh"

sync_swerver

SERVER="${1:-swerver}"
SCENARIO="throughput"
VUS="${K6_VUS:-100}"
DURATION="${K6_DURATION:-30s}"

shift || true
while [[ $# -gt 0 ]]; do
    case $1 in
        --scenario|-s) SCENARIO="$2"; shift 2 ;;
        --vus|-v)      VUS="$2";      shift 2 ;;
        --duration|-d) DURATION="$2"; shift 2 ;;
        *)             echo "Unknown option: $1"; exit 1 ;;
    esac
done

case $SERVER in
    swerver|nginx|httpzig|actix|apisix) ;;
    *) echo "Unknown server: $SERVER (available: swerver, nginx, httpzig, actix, apisix)"; exit 1 ;;
esac

if [[ ! -f "$BENCH_ROOT/k6/scenarios/${SCENARIO}.js" ]]; then
    echo "Unknown scenario: $SCENARIO"
    echo "Available: throughput, latency, connections, concurrent, mixed, spike, payload, keepalive, rapid-fire, error-handling, soak"
    exit 1
fi

ensure_k6_image
PROJECT=$(basename "$BENCH_ROOT" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
NETWORK="${PROJECT}_benchmark"

banner "Single Benchmark"
echo "  Server:   $SERVER"
echo "  Scenario: $SCENARIO"
echo "  VUs:      $VUS"
echo "  Duration: $DURATION"
echo ""

mkdir -p "$BENCH_ROOT/results"
rm -f "$BENCH_ROOT/results/${SERVER}_${SCENARIO}.json"

echo "Building $SERVER..."
(cd "$BENCH_ROOT" && docker-compose build "$SERVER") || { echo "ERROR: build failed" >&2; exit 1; }

cleanup() {
    (cd "$BENCH_ROOT" && docker-compose stop "$SERVER" 2>/dev/null || true)
}
trap cleanup EXIT

echo "Starting $SERVER..."
(cd "$BENCH_ROOT" && docker-compose up -d "$SERVER") || { echo "ERROR: failed to start" >&2; exit 1; }

echo -n "Waiting..."
for i in $(seq 1 30); do
    if (cd "$BENCH_ROOT" && docker-compose exec -T "$SERVER" curl -sSf "http://localhost:8080/health" >/dev/null 2>&1); then
        echo " ready (${i}s)"
        break
    elif (cd "$BENCH_ROOT" && docker-compose exec -T "$SERVER" wget -q --spider "http://localhost:8080/health" 2>/dev/null); then
        echo " ready (${i}s)"
        break
    fi
    echo -n "."
    sleep 1
    if [[ $i -eq 30 ]]; then
        echo " TIMEOUT"
        (cd "$BENCH_ROOT" && docker-compose logs "$SERVER")
        exit 1
    fi
done

echo ""
echo "Running $SCENARIO..."
echo ""

ENV_FLAGS="-e K6_VUS=$VUS -e K6_DURATION=$DURATION"
case "$SCENARIO" in
    payload|keepalive|spike|concurrent|soak) ENV_FLAGS="" ;;
esac

K6_EXIT=0
docker run --rm \
    --network "$NETWORK" \
    -v "$BENCH_ROOT/results:/results" \
    -v "$BENCH_ROOT/k6/scenarios:/scenarios:ro" \
    -v "$BENCH_ROOT/k6/lib:/lib:ro" \
    $ENV_FLAGS \
    -e TARGET_HOST="$SERVER" \
    -e TARGET_PORT=8080 \
    "$K6_IMAGE" \
    "/scenarios/${SCENARIO}.js" || K6_EXIT=$?

[[ $K6_EXIT -ne 0 ]] && echo "WARNING: k6 exited with status $K6_EXIT (thresholds may have failed)"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
if [[ -f "$BENCH_ROOT/results/${SERVER}_${SCENARIO}.json" ]]; then
    DEST="$BENCH_ROOT/results/${SERVER}_${SCENARIO}_${TIMESTAMP}.json"
    mv "$BENCH_ROOT/results/${SERVER}_${SCENARIO}.json" "$DEST"
    echo ""
    echo "Results saved to: $DEST"
else
    echo ""
    echo "WARNING: No result file written"
    exit 1
fi
