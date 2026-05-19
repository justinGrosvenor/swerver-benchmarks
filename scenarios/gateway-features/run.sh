#!/bin/bash
# Run the Gateway Features scenario
# Usage: ./run.sh [--vus <n>] [--duration <time>] [--test <name>]
#
# Set USE_LOCAL_SWERVER=1 to rsync the local working copy instead of cloning.
set -euo pipefail

cd "$(dirname "$0")"
SCENARIO_DIR="$(pwd)"

VUS="${K6_VUS:-100}"
DURATION="${K6_DURATION:-30s}"
SINGLE_TEST=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --vus|-v)      VUS="$2";        shift 2 ;;
        --duration|-d) DURATION="$2";   shift 2 ;;
        --test|-t)     SINGLE_TEST="$2"; shift 2 ;;
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
NETWORK="${COMPOSE_PROJECT}_default"

echo "========================================"
echo "Scenario: Gateway Features"
echo "VUs:      $VUS"
echo "Duration: $DURATION"
if [[ -n "$SINGLE_TEST" ]]; then
    echo "Test:     $SINGLE_TEST"
fi
echo "========================================"
echo ""

mkdir -p results

# Build and start
echo "Building services..."
if ! docker compose build; then
    echo "ERROR: docker compose build failed" >&2
    exit 1
fi
echo "Starting services..."
if ! docker compose up -d; then
    echo "ERROR: docker compose up failed" >&2
    exit 1
fi

# Cleanup on exit
cleanup() {
    echo ""
    echo "Stopping services..."
    docker compose down 2>/dev/null || true
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
        docker compose logs swerver
        exit 1
    fi
done

# Quick smoke test
echo ""
echo "Smoke test..."
echo -n "  /noauth/users: "
STATUS=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/noauth/users)
echo "$STATUS"
echo -n "  /authed/users (with key): "
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-API-Key: bench-key-1' http://localhost:8080/authed/users)
echo "$STATUS"
echo -n "  /authed/users (no key): "
STATUS=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/authed/users)
echo "$STATUS"
echo -n "  /cached/catalog: "
STATUS=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/cached/catalog)
echo "$STATUS"
echo -n "  /canary/version: "
curl -s http://localhost:8080/canary/version
echo ""
echo -n "  /limited/users (with key): "
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-API-Key: limited-key-1' http://localhost:8080/limited/users)
echo "$STATUS"
echo -n "  /validated/validate (valid): "
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"name":"test","email":"a@b.com"}' http://localhost:8080/validated/validate)
echo "$STATUS"
echo -n "  /validated/validate (invalid): "
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"name":""}' http://localhost:8080/validated/validate)
echo "$STATUS"
echo ""

# Test list
if [[ -n "$SINGLE_TEST" ]]; then
    TESTS=("$SINGLE_TEST")
else
    TESTS=("auth-overhead" "rate-limiting" "compression" "caching" "traffic-split" "body-validation" "full-pipeline")
fi

PASS=0
FAIL=0

for TEST in "${TESTS[@]}"; do
    echo "──────────────────────────────────────"
    echo "Running ${TEST}..."
    echo "──────────────────────────────────────"
    echo ""

    if docker run --rm \
        --network "$NETWORK" \
        -v "${SCENARIO_DIR}/results:/results" \
        -v "${SCENARIO_DIR}/k6:/scenarios:ro" \
        -v "${SCENARIO_DIR}/../../k6/lib:/lib:ro" \
        -e TARGET_HOST="swerver" \
        -e TARGET_PORT=8080 \
        "$K6_IMAGE" \
        run "/scenarios/${TEST}.js"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  *** ${TEST} FAILED ***"
    fi
    echo ""
done

echo "========================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "========================================"
echo ""
echo "Result files:"
ls -la results/*.json 2>/dev/null || echo "  (no result files written)"
