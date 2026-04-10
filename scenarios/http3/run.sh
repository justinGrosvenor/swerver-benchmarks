#!/bin/bash
# Run the HTTP/3 (QUIC) benchmark scenario.
#
# Spins up swerver compiled with -Denable-http3 + h2load (with h3 support
# built from source) inside a docker-compose stack, then runs h2load
# against the server's UDP listener for several test profiles:
#
#   throughput  — sustained req/s, 100 concurrent connections
#   connections — connection-rate (handshake cost), new conn per request
#   latency     — single connection, single request at a time
#
# Usage:
#   ./scenarios/http3/run.sh
#   ./scenarios/http3/run.sh --duration 60s --conns 200
#   USE_LOCAL_SWERVER=1 ./scenarios/http3/run.sh
#
# Set USE_LOCAL_SWERVER=1 to rsync the local working copy of swerver
# (../../../swerver from this script) into the build context instead of
# cloning from git.

set -euo pipefail

cd "$(dirname "$0")"
SCENARIO_DIR="$(pwd)"
BENCH_ROOT="$(cd ../.. && pwd)"

# ---- Defaults / args ----
DURATION="30s"
CONNS=100
TOTAL_REQS=200000
TESTS=("throughput" "latency")

while [[ $# -gt 0 ]]; do
    case $1 in
        --duration|-d) DURATION="$2"; shift 2 ;;
        --conns|-c)    CONNS="$2";    shift 2 ;;
        --reqs|-n)     TOTAL_REQS="$2"; shift 2 ;;
        --tests)       IFS=',' read -ra TESTS <<< "$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---- Generate certificate ----
bash certs/generate.sh

# ---- Sync local swerver if requested ----
LOCAL_SWERVER_CONTEXT="../../servers/swerver/swerver-src"
if [[ "${USE_LOCAL_SWERVER:-0}" == "1" ]]; then
    LOCAL_SWERVER_DIR="${LOCAL_SWERVER_DIR:-$(cd ../../.. && pwd)/swerver}"
    if [[ ! -d "$LOCAL_SWERVER_DIR" ]]; then
        echo "USE_LOCAL_SWERVER=1 but $LOCAL_SWERVER_DIR not found" >&2
        exit 1
    fi
    echo "Syncing local swerver from $LOCAL_SWERVER_DIR..."
    rm -rf "$LOCAL_SWERVER_CONTEXT"
    mkdir -p "$LOCAL_SWERVER_CONTEXT"
    rsync -a --delete --exclude='.git' --exclude='.zig-cache' --exclude='zig-out' \
        "$LOCAL_SWERVER_DIR"/ "$LOCAL_SWERVER_CONTEXT"/
else
    rm -rf "$LOCAL_SWERVER_CONTEXT"
fi

COMPOSE_PROJECT="scenario-http3"

dc() {
    docker compose --project-directory "$SCENARIO_DIR" -p "$COMPOSE_PROJECT" "$@"
}

cleanup() {
    echo ""
    echo "Cleaning up..."
    dc down --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p results

echo "========================================"
echo "HTTP/3 Benchmark Suite"
echo "========================================"
echo "Tests:    ${TESTS[*]}"
echo "Conns:    $CONNS"
echo "Reqs:     $TOTAL_REQS"
echo "Duration: $DURATION"
echo "========================================"
echo ""

# ---- Build the loadgen image (and swerver) ----
echo "Building loadgen + swerver images..."
if ! dc --profile loadgen build; then
    echo "ERROR: docker compose build failed" >&2
    exit 1
fi
echo ""

# ---- Start swerver and wait for healthy ----
echo "Starting swerver..."
dc up -d swerver

echo -n "Waiting for swerver to become healthy..."
for i in $(seq 1 60); do
    state=$(dc ps --format json swerver 2>/dev/null | grep -o '"Health":"[a-z]*"' | head -1 | cut -d'"' -f4 || echo unknown)
    if [[ "$state" == "healthy" ]]; then
        echo " ready (${i}s)"
        break
    fi
    echo -n "."
    sleep 1
    if [[ $i -eq 60 ]]; then
        echo " TIMEOUT"
        dc logs swerver | tail -30
        exit 1
    fi
done

# ---- Run h2load tests ----
FAILED=0
run_h2load() {
    local test="$1"
    shift
    local outfile="$SCENARIO_DIR/results/swerver_h3-${test}.txt"
    echo ""
    echo "--- swerver / h3-${test} ---"
    if dc run --rm --no-deps h2load \
            --alpn-list=h3 \
            "$@" \
            https://swerver:9443/echo 2>&1 | tee "$outfile" | tail -12; then
        echo "  OK: $outfile"
    else
        echo "  FAIL: h2load returned non-zero"
        FAILED=$((FAILED + 1))
    fi
}

for test in "${TESTS[@]}"; do
    case "$test" in
        throughput)
            run_h2load throughput \
                -t 4 \
                -c "$CONNS" \
                -n "$TOTAL_REQS"
            ;;
        latency)
            # 1 connection, 1 request at a time, 1000 requests for stable p99
            run_h2load latency \
                -t 1 \
                -c 1 \
                -m 1 \
                -n 1000
            ;;
        connections)
            # New connection per request — handshake cost
            run_h2load connections \
                -t 4 \
                -c 100 \
                -n 1000 \
                --rate 100
            ;;
        *)
            echo "Unknown test: $test" >&2
            FAILED=$((FAILED + 1))
            ;;
    esac
done

echo ""
echo "========================================"
RESULT_COUNT=$(ls results/*.txt 2>/dev/null | wc -l | tr -d ' ')
echo "Results: $RESULT_COUNT files in results/"
if [[ $FAILED -gt 0 ]]; then
    echo "Failures: $FAILED"
    exit 1
fi
echo "========================================"
