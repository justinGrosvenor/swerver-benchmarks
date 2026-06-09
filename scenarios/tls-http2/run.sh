#!/bin/bash
# Run TLS + HTTP/2 benchmark scenarios
# Usage: ./run.sh [--servers "swerver nginx actix"] [--vus <n>] [--duration <time>]
set -euo pipefail

cd "$(dirname "$0")"
SCENARIO_DIR="$(pwd)"
BENCH_ROOT="$(cd ../.. && pwd)"
source "$BENCH_ROOT/lib/common.sh"

SERVERS="${SERVERS:-swerver nginx actix apisix}"
VUS="${BENCH_VUS:-100}"
DURATION="${BENCH_DURATION:-30s}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --servers|-s)  SERVERS="$2";  shift 2 ;;
        --vus|-v)      VUS="$2";      shift 2 ;;
        --duration|-d) DURATION="$2"; shift 2 ;;
        *)             echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Generate certificates if needed
bash certs/generate.sh

sync_swerver

ensure_k6_image
PROJECT="tls-http2"
NETWORK="${PROJECT}_scenario"

DEFAULT_TESTS=("tls-throughput" "tls-handshake" "h2-throughput" "h2-post-body" "h2-large-response" "h2-multiplexing" "h2-many-headers" "h2-concurrent-streams" "h2-mixed-workload" "h2-static-files" "h2-json-compressed")
SOAK_TESTS=("h2-connection-longevity")

if [[ -n "${TESTS_OVERRIDE:-}" ]]; then
    IFS=',' read -ra TESTS <<< "$TESTS_OVERRIDE"
elif [[ "${INCLUDE_SOAK:-0}" == "1" ]]; then
    TESTS=("${DEFAULT_TESTS[@]}" "${SOAK_TESTS[@]}")
else
    TESTS=("${DEFAULT_TESTS[@]}")
fi
FAILED=0

banner "TLS + HTTP/2 Benchmark Suite"
echo "  Servers:  $SERVERS"
echo "  Tests:    ${TESTS[*]}"
echo "  VUs:      $VUS"
echo "  Duration: $DURATION"
echo ""

mkdir -p results
rm -f results/*.json

cleanup() {
    echo ""
    echo "Stopping services..."
    dc "$SCENARIO_DIR" "$PROJECT" down --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

echo "Building servers..."
dc "$SCENARIO_DIR" "$PROJECT" build $SERVERS 2>&1 | tail -5
echo ""

for server in $SERVERS; do
    banner "Testing: $server (TLS)"

    local_port=8443
    [[ "$server" == "apisix" ]] && local_port=9443

    dc "$SCENARIO_DIR" "$PROJECT" stop 2>/dev/null || true
    dc "$SCENARIO_DIR" "$PROJECT" up -d "$server" 2>/dev/null

    if ! wait_healthy "$SCENARIO_DIR" "$PROJECT" "$server" "curl -sSfk https://localhost:${local_port}/health" 60; then
        echo "  SKIP: $server failed to start"
        dc "$SCENARIO_DIR" "$PROJECT" logs "$server" 2>&1 | tail -10 || true
        FAILED=$((FAILED + 1))
        continue
    fi

    for test in "${TESTS[@]}"; do
        echo ""
        echo "--- $server / $test ---"

        k6_log=$(mktemp)
        set +e
        docker run --rm \
            --network "$NETWORK" \
            -v "$SCENARIO_DIR/k6:/scenarios:ro" \
            -v "$BENCH_ROOT/k6/lib:/lib:ro" \
            -e "BENCH_VUS=$VUS" \
            -e "BENCH_DURATION=$DURATION" \
            -e "TARGET_HOST=$server" \
            -e "TARGET_PORT=$local_port" \
            "$K6_IMAGE" \
            "/scenarios/${test}.js" > "$k6_log" 2>&1
        set -e
        grep -E "^(Summary| |running)" "$k6_log" | tail -8

        result_file="results/${server}_${test}.json"
        if sed -n '/__RESULT_JSON_START__/,/__RESULT_JSON_END__/p' "$k6_log" \
            | grep -v '__RESULT_JSON_' > "$result_file" 2>/dev/null \
            && [[ -s "$result_file" ]]; then
            echo "  OK: $result_file"
        else
            rm -f "$result_file"
            grep -i "level=error" "$k6_log" | tail -3 || true
            echo "  FAIL: no result data"
            FAILED=$((FAILED + 1))
        fi
        rm -f "$k6_log"
    done

    echo ""
    dc "$SCENARIO_DIR" "$PROJECT" stop "$server" 2>/dev/null || true
done

echo ""
banner "Summary"
RESULT_COUNT=$(ls results/*.json 2>/dev/null | wc -l | tr -d ' ')
echo "  Results: $RESULT_COUNT files in results/"
[[ $FAILED -gt 0 ]] && echo "  Failures: $FAILED"
