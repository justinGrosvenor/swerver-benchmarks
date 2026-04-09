#!/bin/bash
# Run all practical proxy scenarios (swerver-only)
# Usage: ./run-scenarios.sh [--scenarios "load-balancer api-gateway static-api"]
#
# Each scenario spins up swerver + backend microservices, runs k6 tests,
# and collects results.
#
# By default the swerver Dockerfile clones SWERVER_REF (default: main) so numbers
# are reproducible across machines. Set USE_LOCAL_SWERVER=1 to rsync the local
# working copy at ../swerver into the build context instead.

set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BENCH_ROOT"

SCENARIOS="${1:-load-balancer api-gateway static-api}"
K6_IMAGE="swerver-bench-k6"
RESULTS_DIR="$BENCH_ROOT/results/scenarios_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo "========================================"
echo "Scenario Tests (swerver reverse proxy)"
echo "========================================"
echo "Scenarios: $SCENARIOS"
echo "Results:   $RESULTS_DIR"
echo "========================================"
echo ""

# ---- Sync swerver sources (opt-in) ----
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
    rsync -a --delete \
        --exclude='.git' --exclude='.zig-cache' --exclude='zig-out' \
        "$LOCAL_SWERVER_DIR"/ "$LOCAL_SWERVER_CONTEXT"/
else
    rm -rf "$LOCAL_SWERVER_CONTEXT"
fi

# ---- Build k6 image ----
echo "Building k6..."
if ! docker build -t "$K6_IMAGE" ./k6; then
    echo "ERROR: k6 image build failed" >&2
    exit 1
fi
echo ""

# ---- Compose helper (always runs from scenario dir) ----
dc() {
    local scenario_dir="$1"
    shift
    docker compose --project-directory "$scenario_dir" -p "$COMPOSE_PROJECT" "$@"
}

# ---- Run a k6 test within a scenario ----
run_k6() {
    local scenario_dir="$1"
    local test_name="$2"
    local network="$3"
    local scenario_slug="$4"

    echo "  --- $test_name ---"

    # The grep|tail pipe is intentionally fault-tolerant under set -euo pipefail.
    # Success is judged by whether the JSON result file lands on disk.
    set +e
    docker run --rm \
        --network "$network" \
        -v "$BENCH_ROOT/results:/results" \
        -v "${scenario_dir}/k6:/scenarios:ro" \
        -v "$BENCH_ROOT/k6/lib:/lib:ro" \
        -e TARGET_HOST=swerver \
        -e TARGET_PORT=8080 \
        -e K6_VUS=100 \
        -e K6_DURATION=30s \
        "$K6_IMAGE" \
        "/scenarios/${test_name}.js" 2>&1 | grep -E "^(Summary| |running )" | tail -5
    set -e

    # Find and move result file
    local result_file
    result_file=$(ls -t "$BENCH_ROOT"/results/${scenario_slug}*.json 2>/dev/null | head -1)
    if [[ -n "$result_file" && -f "$result_file" ]]; then
        mv "$result_file" "$RESULTS_DIR/"
        echo "  OK: $(basename "$result_file")"
    else
        echo "  WARN: no result file for $test_name"
    fi
    echo ""
}

# ---- Wait for swerver to be healthy ----
wait_for_healthy() {
    local scenario_dir="$1"
    echo -n "  Waiting for swerver..."
    for i in $(seq 1 60); do
        if dc "$scenario_dir" exec -T swerver curl -sSf "http://localhost:8080/health" >/dev/null 2>&1; then
            echo " ready (${i}s)"
            return 0
        fi
        sleep 1
        echo -n "."
    done
    echo " TIMEOUT"
    dc "$scenario_dir" logs swerver 2>&1 | tail -20 || true
    return 1
}

# ---- Main loop ----
for scenario in $SCENARIOS; do
    SCENARIO_DIR="$BENCH_ROOT/scenarios/$scenario"
    if [[ ! -f "$SCENARIO_DIR/docker-compose.yml" ]]; then
        echo "SKIP: $scenario (no docker-compose.yml)"
        continue
    fi

    echo "========================================"
    echo "Scenario: $scenario"
    echo "========================================"

    COMPOSE_PROJECT="scenario-${scenario}"
    NETWORK="${COMPOSE_PROJECT}_default"

    # Build and start
    echo "  Building..."
    if ! dc "$SCENARIO_DIR" build; then
        echo "  ERROR: build failed for $scenario" >&2
        continue
    fi
    echo "  Starting..."
    if ! dc "$SCENARIO_DIR" up -d; then
        echo "  ERROR: failed to start $scenario" >&2
        dc "$SCENARIO_DIR" down 2>/dev/null || true
        continue
    fi

    if ! wait_for_healthy "$SCENARIO_DIR"; then
        echo "  SKIP: swerver failed to start"
        dc "$SCENARIO_DIR" down 2>/dev/null || true
        continue
    fi

    # Run k6 tests for this scenario
    K6_TESTS=$(ls "$SCENARIO_DIR/k6/"*.js 2>/dev/null | xargs -n1 basename | sed 's/\.js$//')
    for test in $K6_TESTS; do
        case "$scenario" in
            load-balancer)  slug="lb-${test}" ;;
            api-gateway)    slug="api-gateway-${test}" ;;
            static-api)     slug="static-api-${test}" ;;
            *)              slug="${scenario}-${test}" ;;
        esac
        run_k6 "$SCENARIO_DIR" "$test" "$NETWORK" "$slug"
    done

    # Teardown
    echo "  Cleaning up $scenario..."
    dc "$SCENARIO_DIR" down 2>/dev/null || true
    echo ""
done

echo "========================================"
echo "All scenario results in: $RESULTS_DIR"
echo "========================================"
ls -la "$RESULTS_DIR/" 2>/dev/null

# Print summary of results
echo ""
echo "========================================"
echo "Results Summary"
echo "========================================"
for f in "$RESULTS_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f" .json)
    rps=$(python3 -c "import json; d=json.load(open('$f')); print(f\"{d['metrics'].get('requests_per_second', d['metrics'].get('', 0)):.0f}\")" 2>/dev/null || echo "?")
    p99=$(python3 -c "import json; d=json.load(open('$f')); print(f\"{d['metrics'].get('latency_p99_ms', 0):.2f}\")" 2>/dev/null || echo "?")
    echo "  $name: ${rps} req/s, p99=${p99}ms"
done
