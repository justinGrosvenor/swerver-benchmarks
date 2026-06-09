#!/bin/bash
# Run all practical proxy scenarios (swerver-only)
# Usage: ./run-scenarios.sh [load-balancer api-gateway static-api gateway-features]
#
# Set USE_LOCAL_SWERVER=1 to rsync the local working copy.

set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$BENCH_ROOT/lib/common.sh"

SCENARIOS="${1:-load-balancer api-gateway static-api gateway-features}"
ensure_k6_image
init_results "scenarios"

banner "Scenario Tests (swerver reverse proxy)"
echo "  Scenarios: $SCENARIOS"
echo "  Results:   $RESULTS_DIR"
echo ""

sync_swerver

for scenario in $SCENARIOS; do
    SCENARIO_DIR="$BENCH_ROOT/scenarios/$scenario"
    if [[ ! -f "$SCENARIO_DIR/docker-compose.yml" ]]; then
        echo "SKIP: $scenario (no docker-compose.yml)"
        continue
    fi

    banner "Scenario: $scenario"

    PROJECT="scenario-${scenario}"
    NETWORK="${PROJECT}_default"

    echo "  Building..."
    dc "$SCENARIO_DIR" "$PROJECT" build 2>&1 | tail -3
    echo "  Starting..."
    dc "$SCENARIO_DIR" "$PROJECT" up -d

    if ! wait_healthy "$SCENARIO_DIR" "$PROJECT" "swerver" "curl -sSf http://localhost:8080/health" 60; then
        echo "  SKIP: swerver failed to start"
        dc "$SCENARIO_DIR" "$PROJECT" down 2>/dev/null || true
        continue
    fi

    K6_TESTS=$(ls "$SCENARIO_DIR/k6/"*.js 2>/dev/null | xargs -n1 basename | sed 's/\.js$//')
    for test in $K6_TESTS; do
        case "$scenario" in
            load-balancer)      slug="lb-${test}" ;;
            api-gateway)        slug="api-gateway-${test}" ;;
            static-api)         slug="static-api-${test}" ;;
            gateway-features)   slug="${test}" ;;
            *)                  slug="${scenario}-${test}" ;;
        esac

        echo "  --- $test ---"
        set +e
        docker run --rm \
            --network "$NETWORK" \
            -v "$RESULTS_DIR:/results" \
            -v "$SCENARIO_DIR/k6:/scenarios:ro" \
            -v "$BENCH_ROOT/k6/lib:/lib:ro" \
            -e TARGET_HOST=swerver \
            -e TARGET_PORT=8080 \
            -e K6_VUS=100 \
            -e K6_DURATION=30s \
            "$K6_IMAGE" \
            "/scenarios/${test}.js" 2>&1 | grep -E "^(Summary| |running )" | tail -5
        set -e

        local_result=$(ls -t "$RESULTS_DIR"/${slug}*.json 2>/dev/null | head -1)
        if [[ -n "$local_result" && -f "$local_result" ]]; then
            echo "  OK: $(basename "$local_result")"
        else
            echo "  WARN: no result file for $test"
        fi
        echo ""
    done

    echo "  Cleaning up $scenario..."
    dc "$SCENARIO_DIR" "$PROJECT" down 2>/dev/null || true
    echo ""
done

banner "All scenario results in: $RESULTS_DIR"
ls -la "$RESULTS_DIR/" 2>/dev/null

echo ""
banner "Results Summary"
for f in "$RESULTS_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f" .json)
    rps=$(python3 -c "import json; d=json.load(open('$f')); print(f\"{d['metrics'].get('requests_per_second', d['metrics'].get('', 0)):.0f}\")" 2>/dev/null || echo "?")
    p99=$(python3 -c "import json; d=json.load(open('$f')); print(f\"{d['metrics'].get('latency_p99_ms', 0):.2f}\")" 2>/dev/null || echo "?")
    echo "  $name: ${rps} req/s, p99=${p99}ms"
done
