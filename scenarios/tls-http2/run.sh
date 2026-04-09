#!/bin/bash
# Run TLS + HTTP/2 benchmark scenarios
# Usage: ./run.sh [--servers "swerver nginx actix"] [--vus <n>] [--duration <time>]
set -e

cd "$(dirname "$0")"
SCENARIO_DIR="$(pwd)"

SERVERS="${SERVERS:-swerver nginx actix apisix}"
VUS="${K6_VUS:-100}"
DURATION="${K6_DURATION:-30s}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --servers|-s)  SERVERS="$2";  shift 2 ;;
        --vus|-v)      VUS="$2";      shift 2 ;;
        --duration|-d) DURATION="$2"; shift 2 ;;
        *)             echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ---- Generate certificates if needed ----
bash certs/generate.sh

# ---- Sync local swerver sources ----
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
TESTS=("tls-throughput" "tls-handshake" "h2-throughput")
FAILED=0

echo "========================================"
echo "TLS + HTTP/2 Benchmark Suite"
echo "========================================"
echo "Servers:  $SERVERS"
echo "Tests:    ${TESTS[*]}"
echo "VUs:      $VUS"
echo "Duration: $DURATION"
echo "========================================"
echo ""

mkdir -p results
rm -f results/*.json

# Cleanup on exit
cleanup() {
    echo ""
    echo "Stopping services..."
    docker-compose down --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

# ---- Build all servers ----
echo "Building servers..."
docker-compose build $SERVERS 2>&1 | tail -5
echo ""

# ---- Run benchmarks per server ----
for server in $SERVERS; do
    echo "========================================"
    echo "Testing: $server (TLS)"
    echo "========================================"

    # APISIX uses a different internal port (9443 instead of 8443)
    internal_port=8443
    if [[ "$server" == "apisix" ]]; then
        internal_port=9443
    fi

    # Stop everything, start only this server
    docker-compose stop 2>/dev/null || true
    docker-compose up -d "$server" 2>/dev/null

    # Wait for healthy
    echo -n "  Waiting for $server..."
    for i in $(seq 1 60); do
        if docker-compose exec -T "$server" curl -sSfk "https://localhost:${internal_port}/health" >/dev/null 2>&1; then
            echo " ready (${i}s)"
            break
        elif docker-compose exec -T "$server" wget -q --spider --no-check-certificate "https://localhost:${internal_port}/health" 2>/dev/null; then
            echo " ready (${i}s)"
            break
        fi
        echo -n "."
        sleep 1
        if [[ $i -eq 60 ]]; then
            echo " TIMEOUT"
            docker-compose logs "$server"
            FAILED=$((FAILED + 1))
            continue 2
        fi
    done

    for test in "${TESTS[@]}"; do
        echo ""
        echo "--- $server / $test ---"

        # tls-handshake has its own VU/duration config (new conn per request is slower)
        local_env="-e K6_VUS=$VUS -e K6_DURATION=$DURATION"
        if [[ "$test" == "tls-handshake" ]]; then
            local_env="-e K6_VUS=$VUS -e K6_DURATION=$DURATION"
        fi

        docker run --rm \
            --network "$NETWORK" \
            -v "${SCENARIO_DIR}/results:/results" \
            -v "${SCENARIO_DIR}/k6:/scenarios:ro" \
            -v "${SCENARIO_DIR}/../../k6/lib:/lib:ro" \
            $local_env \
            -e TARGET_HOST="$server" \
            -e TARGET_PORT="$internal_port" \
            "$K6_IMAGE" \
            run "/scenarios/${test}.js" 2>&1 | grep -E "^(Summary| |running)" | tail -5

        if [[ -f "results/${server}_${test}.json" ]]; then
            echo "  OK: results/${server}_${test}.json"
        else
            echo "  FAIL: no result file"
            FAILED=$((FAILED + 1))
        fi
    done

    echo ""
    docker-compose stop "$server" 2>/dev/null || true
done

# ---- Summary ----
echo ""
echo "========================================"
RESULT_COUNT=$(ls results/*.json 2>/dev/null | wc -l | tr -d ' ')
echo "Results: $RESULT_COUNT files in results/"

if [[ $FAILED -gt 0 ]]; then
    echo "Failures: $FAILED"
fi
echo "========================================"
