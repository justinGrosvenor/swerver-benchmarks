#!/bin/bash
# Run the Gateway Features scenario
# Usage: ./run.sh [--vus <n>] [--duration <time>] [--test <name>]
#
# Set USE_LOCAL_SWERVER=1 to rsync the local working copy instead of cloning.
set -euo pipefail

cd "$(dirname "$0")"
SCENARIO_DIR="$(pwd)"
BENCH_ROOT="$(cd ../.. && pwd)"
source "$BENCH_ROOT/lib/common.sh"

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

sync_swerver

ensure_k6_image
PROJECT="gateway-features"
NETWORK="${PROJECT}_default"

banner "Scenario: Gateway Features"
echo "  VUs:      $VUS"
echo "  Duration: $DURATION"
[[ -n "$SINGLE_TEST" ]] && echo "  Test:     $SINGLE_TEST"
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

# Smoke test
echo ""
echo "Smoke test..."
echo -n "  /noauth/users: "
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/noauth/users || echo "FAIL"
echo -n "  /authed/users (with key): "
curl -s -o /dev/null -w '%{http_code}\n' -H 'X-API-Key: bench-key-1' http://localhost:8080/authed/users || echo "FAIL"
echo -n "  /authed/users (no key): "
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/authed/users || echo "FAIL"
echo -n "  /cached/catalog: "
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/cached/catalog || echo "FAIL"
echo -n "  /canary/version: "
curl -s http://localhost:8080/canary/version || echo "FAIL"
echo ""
echo -n "  /limited/users (with key): "
curl -s -o /dev/null -w '%{http_code}\n' -H 'X-API-Key: limited-key-1' http://localhost:8080/limited/users || echo "FAIL"
echo -n "  /validated/validate (valid): "
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{"name":"test","email":"a@b.com"}' http://localhost:8080/validated/validate || echo "FAIL"
echo -n "  /validated/validate (invalid): "
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{"name":""}' http://localhost:8080/validated/validate || echo "FAIL"
echo ""

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
        -v "$SCENARIO_DIR/results:/results" \
        -v "$SCENARIO_DIR/k6:/scenarios:ro" \
        -v "$BENCH_ROOT/k6/lib:/lib:ro" \
        -e TARGET_HOST=swerver \
        -e TARGET_PORT=8080 \
        "$K6_IMAGE" \
        "/scenarios/${TEST}.js"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  *** ${TEST} FAILED ***"
    fi
    echo ""
done

banner "Results: ${PASS} passed, ${FAIL} failed"
echo ""
echo "Result files:"
ls -la results/*.json 2>/dev/null || echo "  (no result files written)"
