#!/bin/bash
# Run the HTTP/3 (QUIC) benchmark scenario.
#
# Usage:
#   ./run.sh
#   ./run.sh --duration 60s --conns 200
#   USE_LOCAL_SWERVER=1 ./run.sh
set -euo pipefail

cd "$(dirname "$0")"
SCENARIO_DIR="$(pwd)"
BENCH_ROOT="$(cd ../.. && pwd)"
source "$BENCH_ROOT/lib/common.sh"

DURATION="30s"
CONNS=100
TOTAL_REQS=200000
DEFAULT_TESTS=("throughput" "latency")
EXTENDED_TESTS=("post-body" "large-post" "high-streams" "sustained" "connections" "mixed-payload")

if [[ -n "${TESTS_OVERRIDE:-}" ]]; then
    IFS=',' read -ra TESTS <<< "$TESTS_OVERRIDE"
elif [[ "${INCLUDE_EXTENDED:-0}" == "1" ]]; then
    TESTS=("${DEFAULT_TESTS[@]}" "${EXTENDED_TESTS[@]}")
else
    TESTS=("${DEFAULT_TESTS[@]}")
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --duration|-d) DURATION="$2"; shift 2 ;;
        --conns|-c)    CONNS="$2";    shift 2 ;;
        --reqs|-n)     TOTAL_REQS="$2"; shift 2 ;;
        --tests)       IFS=',' read -ra TESTS <<< "$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

bash certs/generate.sh
sync_swerver

PROJECT="scenario-http3"

cleanup() {
    echo ""
    echo "Cleaning up..."
    dc "$SCENARIO_DIR" "$PROJECT" down --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p results

banner "HTTP/3 Benchmark Suite"
echo "  Tests:    ${TESTS[*]}"
echo "  Conns:    $CONNS"
echo "  Reqs:     $TOTAL_REQS"
echo "  Duration: $DURATION"
echo ""

# Generate data files for POST tests
DATA_DIR="$SCENARIO_DIR/data"
mkdir -p "$DATA_DIR"
needs_post=false
for t in "${TESTS[@]}"; do
    case "$t" in post-body|large-post|mixed-payload) needs_post=true ;; esac
done
if $needs_post; then
    echo "Generating POST data files..."
    [[ -f "$DATA_DIR/32k.bin" ]] || dd if=/dev/urandom of="$DATA_DIR/32k.bin" bs=1024 count=32 2>/dev/null
    [[ -f "$DATA_DIR/128k.bin" ]] || dd if=/dev/urandom of="$DATA_DIR/128k.bin" bs=1024 count=128 2>/dev/null
    [[ -f "$DATA_DIR/512b.bin" ]] || dd if=/dev/urandom of="$DATA_DIR/512b.bin" bs=512 count=1 2>/dev/null
    [[ -f "$DATA_DIR/8k.bin" ]] || dd if=/dev/urandom of="$DATA_DIR/8k.bin" bs=1024 count=8 2>/dev/null
    [[ -f "$DATA_DIR/64k.bin" ]] || dd if=/dev/urandom of="$DATA_DIR/64k.bin" bs=1024 count=64 2>/dev/null
fi

echo "Building loadgen + swerver images..."
dc "$SCENARIO_DIR" "$PROJECT" --profile loadgen build 2>&1 | tail -3
echo ""

echo "Starting swerver..."
dc "$SCENARIO_DIR" "$PROJECT" up -d swerver

echo -n "  Waiting for healthy..."
for i in $(seq 1 60); do
    state=$(dc "$SCENARIO_DIR" "$PROJECT" ps --format json swerver 2>/dev/null \
        | grep -o '"Health":"[a-z]*"' | head -1 | cut -d'"' -f4 || echo unknown)
    if [[ "$state" == "healthy" ]]; then
        echo " ready (${i}s)"
        break
    fi
    echo -n "."
    sleep 1
    if [[ $i -eq 60 ]]; then
        echo " TIMEOUT"
        dc "$SCENARIO_DIR" "$PROJECT" logs swerver | tail -30
        exit 1
    fi
done

FAILED=0
run_h2load() {
    local test="$1"
    shift
    local outfile="$SCENARIO_DIR/results/swerver_h3-${test}.txt"
    echo ""
    echo "--- swerver / h3-${test} ---"
    if dc "$SCENARIO_DIR" "$PROJECT" run --rm --no-deps \
            -v "${SCENARIO_DIR}/data:/data:ro" \
            h2load \
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
        throughput)     run_h2load throughput -t 4 -c "$CONNS" -n "$TOTAL_REQS" ;;
        latency)        run_h2load latency -t 1 -c 1 -m 1 -n 1000 ;;
        connections)    run_h2load connections -t 4 -c 100 -n 1000 --rate 100 ;;
        post-body)      run_h2load post-body -t 4 -c "$CONNS" -n "$TOTAL_REQS" -d /data/32k.bin ;;
        large-post)     run_h2load large-post -t 4 -c 50 -n 50000 -d /data/128k.bin ;;
        high-streams)   run_h2load high-streams -t 4 -c 10 -m 100 -n 500000 ;;
        sustained)      run_h2load sustained -t 4 -c "$CONNS" -D 120 ;;
        mixed-payload)
            for size in 512b 8k 64k; do
                run_h2load "mixed-payload-${size}" -t 4 -c 50 -n 100000 -d "/data/${size}.bin"
            done ;;
        *) echo "Unknown test: $test" >&2; FAILED=$((FAILED + 1)) ;;
    esac
done

echo ""
banner "Summary"
RESULT_COUNT=$(ls results/*.txt 2>/dev/null | wc -l | tr -d ' ')
echo "  Results: $RESULT_COUNT files in results/"
[[ $FAILED -gt 0 ]] && echo "  Failures: $FAILED" && exit 1
