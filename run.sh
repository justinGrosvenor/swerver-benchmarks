#!/bin/bash
# Unified benchmark runner for swerver.
#
# Usage:
#   ./run.sh                          # Run all suites
#   ./run.sh h1                       # Just H1 core
#   ./run.sh h1 h2 h3                 # H1 + TLS/H2 + H3
#   ./run.sh proxy gateway            # Load-balancer + api-gateway + gateway-features
#   ./run.sh --vus 200 --duration 60s # Override defaults
#
# Environment:
#   USE_LOCAL_SWERVER=1  — rsync local working copy instead of git clone
#   SERVERS="swerver"    — for H1 core, which servers to test (default: swerver only)

set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$BENCH_ROOT/lib/common.sh"

# ---- Defaults ----
VUS="${K6_VUS:-100}"
DURATION="${K6_DURATION:-30s}"
SERVERS="${SERVERS:-swerver}"
SUITES=()

# ---- Parse args ----
while [[ $# -gt 0 ]]; do
    case $1 in
        --vus|-v)      VUS="$2";      shift 2 ;;
        --duration|-d) DURATION="$2"; shift 2 ;;
        --servers|-s)  SERVERS="$2";  shift 2 ;;
        h1|h2|h3|proxy|gateway|all)
            case $1 in
                all)     SUITES+=(h1 h2 h3 proxy gateway) ;;
                proxy)   SUITES+=(load-balancer) ;;
                gateway) SUITES+=(api-gateway gateway-features) ;;
                *)       SUITES+=("$1") ;;
            esac
            shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Default: run everything
if [[ ${#SUITES[@]} -eq 0 ]]; then
    SUITES=(h1 h2 h3 load-balancer api-gateway gateway-features)
fi

# Deduplicate
SUITES=($(printf '%s\n' "${SUITES[@]}" | awk '!seen[$0]++'))

# ---- Init ----
sync_swerver
init_results

K6_IMAGE="swerver-bench-k6"

echo "Building k6 image..."
docker build -t "$K6_IMAGE" "$BENCH_ROOT/k6" 2>&1 | tail -2
echo ""

banner "Swerver Benchmark Suite"
echo "  Suites:   ${SUITES[*]}"
echo "  VUs:      $VUS"
echo "  Duration: $DURATION"
echo "  Servers:  $SERVERS"
echo "  Results:  $RESULTS_DIR"
echo "========================================"
echo ""

TOTAL_PASS=0
TOTAL_FAIL=0

# ---- Suite: H1 Core ----
run_h1() {
    banner "H1 Core Benchmarks"
    local suite_dir="$RESULTS_DIR/h1"
    mkdir -p "$suite_dir"

    local project
    project=$(basename "$BENCH_ROOT" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
    local network="${project}_benchmark"
    local k6_dir="$BENCH_ROOT/k6/scenarios"

    h1_dc() { docker compose --project-directory "$BENCH_ROOT" "$@"; }

    # Build servers
    echo "Building servers: $SERVERS"
    h1_dc build $SERVERS 2>&1 | tail -3
    echo ""

    local scenarios="throughput latency connections concurrent mixed spike keepalive rapid-fire error-handling"

    for server in $SERVERS; do
        banner "H1: $server"

        h1_dc stop 2>/dev/null || true
        h1_dc up -d "$server" 2>/dev/null

        echo -n "  Waiting for $server..."
        local ready=0
        for i in $(seq 1 30); do
            if h1_dc exec -T "$server" curl -sSf "http://localhost:8080/health" >/dev/null 2>&1; then
                echo " ready (${i}s)"
                ready=1
                break
            fi
            echo -n "."
            sleep 1
        done
        if [[ $ready -eq 0 ]]; then
            echo " TIMEOUT"
            h1_dc logs "$server" 2>&1 | tail -10 || true
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            continue
        fi

        for scenario in $scenarios; do
            local slug="${server}_${scenario}"
            local docker_args=(
                docker run --rm
                --network "$network"
                -v "$suite_dir:/results"
                -v "$k6_dir:/scenarios:ro"
                -v "$BENCH_ROOT/k6/lib:/lib:ro"
                -e "TARGET_HOST=$server"
                -e "TARGET_PORT=8080"
            )

            # Scenarios with custom executors must not receive VUS/DURATION
            case "$scenario" in
                payload|keepalive|spike|concurrent|soak) ;;
                *) docker_args+=(-e "K6_VUS=$VUS" -e "K6_DURATION=$DURATION") ;;
            esac

            docker_args+=("$K6_IMAGE" "/scenarios/${scenario}.js")

            echo ""
            echo "--- $server / $scenario ---"
            set +e
            "${docker_args[@]}" 2>&1 | grep -E "^(Summary| |running \(0m(29|30))" | tail -5
            set -e

            if [[ -f "$suite_dir/${server}_${scenario}.json" ]]; then
                echo "  OK: $suite_dir/${server}_${scenario}.json"
                TOTAL_PASS=$((TOTAL_PASS + 1))
            else
                echo "  FAIL: no result file"
                TOTAL_FAIL=$((TOTAL_FAIL + 1))
            fi
        done

        h1_dc stop "$server" 2>/dev/null || true
    done

    h1_dc down --remove-orphans 2>/dev/null || true
}

# ---- Suite: TLS / HTTP/2 ----
run_h2() {
    banner "TLS + HTTP/2 Benchmarks"
    local suite_dir="$RESULTS_DIR/h2"
    mkdir -p "$suite_dir"

    local scenario_dir="$BENCH_ROOT/scenarios/tls-http2"
    local project="tls-http2"
    local network="${project}_scenario"
    local k6_dir="$scenario_dir/k6"

    # Generate certs
    bash "$scenario_dir/certs/generate.sh"

    local tests=("tls-throughput" "tls-handshake" "h2-throughput" "h2-post-body" "h2-large-response" "h2-multiplexing" "h2-many-headers" "h2-concurrent-streams" "h2-mixed-workload" "h2-static-files" "h2-json-compressed")
    local tls_servers="swerver"

    # Build
    echo "Building TLS servers..."
    dc "$scenario_dir" "$project" build $tls_servers 2>&1 | tail -3
    echo ""

    for server in $tls_servers; do
        banner "TLS/H2: $server"

        local internal_port=8443
        [[ "$server" == "apisix" ]] && internal_port=9443

        dc "$scenario_dir" "$project" stop 2>/dev/null || true
        dc "$scenario_dir" "$project" up -d "$server" 2>/dev/null

        if ! wait_healthy "$scenario_dir" "$project" "$server" "curl -sSfk https://localhost:${internal_port}/health" 60; then
            echo "  SKIP: $server failed to start"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            continue
        fi

        for test in "${tests[@]}"; do
            local slug="${server}_${test}"
            echo ""
            echo "--- $server / $test ---"

            local k6_log
            k6_log=$(mktemp)
            set +e
            docker run --rm \
                --network "$network" \
                -v "${k6_dir}:/scenarios:ro" \
                -v "$BENCH_ROOT/k6/lib:/lib:ro" \
                -e "BENCH_VUS=$VUS" \
                -e "BENCH_DURATION=$DURATION" \
                -e "TARGET_HOST=$server" \
                -e "TARGET_PORT=$internal_port" \
                "$K6_IMAGE" \
                "/scenarios/${test}.js" > "$k6_log" 2>&1
            set -e

            grep -E "^(Summary| |running)" "$k6_log" | tail -8

            # Extract JSON from stdout delimiters
            local result_file="$suite_dir/${slug}.json"
            if sed -n '/__RESULT_JSON_START__/,/__RESULT_JSON_END__/p' "$k6_log" \
                | grep -v '__RESULT_JSON_' > "$result_file" 2>/dev/null \
                && [[ -s "$result_file" ]]; then
                echo "  OK: $result_file"
                TOTAL_PASS=$((TOTAL_PASS + 1))
            else
                rm -f "$result_file"
                grep -i "level=error" "$k6_log" | tail -3 || true
                echo "  FAIL: no result data"
                TOTAL_FAIL=$((TOTAL_FAIL + 1))
            fi
            rm -f "$k6_log"
        done

        dc "$scenario_dir" "$project" stop "$server" 2>/dev/null || true
    done

    dc "$scenario_dir" "$project" down --remove-orphans 2>/dev/null || true
}

# ---- Suite: HTTP/3 ----
run_h3() {
    banner "HTTP/3 (QUIC) Benchmarks"
    local suite_dir="$RESULTS_DIR/h3"
    mkdir -p "$suite_dir"

    local scenario_dir="$BENCH_ROOT/scenarios/http3"
    local project="scenario-http3"

    # Generate certs
    bash "$scenario_dir/certs/generate.sh"

    local conns=100
    local total_reqs=200000

    # Build
    echo "Building H3 images..."
    dc "$scenario_dir" "$project" --profile loadgen build 2>&1 | tail -3
    echo ""

    # Start swerver
    echo "Starting swerver (H3)..."
    dc "$scenario_dir" "$project" up -d swerver

    echo -n "  Waiting for healthy..."
    for i in $(seq 1 60); do
        local state
        state=$(dc "$scenario_dir" "$project" ps --format json swerver 2>/dev/null | grep -o '"Health":"[a-z]*"' | head -1 | cut -d'"' -f4 || echo unknown)
        if [[ "$state" == "healthy" ]]; then
            echo " ready (${i}s)"
            break
        fi
        echo -n "."
        sleep 1
        if [[ $i -eq 60 ]]; then
            echo " TIMEOUT"
            dc "$scenario_dir" "$project" logs swerver | tail -20
            dc "$scenario_dir" "$project" down --remove-orphans 2>/dev/null || true
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            return
        fi
    done

    # Throughput test
    echo ""
    echo "--- h3-throughput ---"
    local outfile="$suite_dir/swerver_h3-throughput.txt"
    set +e
    dc "$scenario_dir" "$project" run --rm --no-deps \
        h2load --alpn-list=h3 -t 4 -c "$conns" -n "$total_reqs" \
        https://swerver:9443/echo 2>&1 | tee "$outfile" | tail -12
    set -e
    if [[ -s "$outfile" ]]; then
        echo "  OK: $outfile"
        TOTAL_PASS=$((TOTAL_PASS + 1))
    else
        echo "  FAIL"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi

    # Latency test
    echo ""
    echo "--- h3-latency ---"
    outfile="$suite_dir/swerver_h3-latency.txt"
    set +e
    dc "$scenario_dir" "$project" run --rm --no-deps \
        h2load --alpn-list=h3 -t 1 -c 1 -m 1 -n 1000 \
        https://swerver:9443/echo 2>&1 | tee "$outfile" | tail -12
    set -e
    if [[ -s "$outfile" ]]; then
        echo "  OK: $outfile"
        TOTAL_PASS=$((TOTAL_PASS + 1))
    else
        echo "  FAIL"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi

    dc "$scenario_dir" "$project" down --remove-orphans 2>/dev/null || true
}

# ---- Suite: Generic proxy/gateway scenario ----
# Shared by load-balancer, api-gateway, gateway-features
run_scenario() {
    local name="$1"
    local scenario_dir="$BENCH_ROOT/scenarios/$name"
    local suite_dir="$RESULTS_DIR/$name"
    mkdir -p "$suite_dir"

    local project="bench-${name}"
    local network="${project}_default"
    local k6_dir="$scenario_dir/k6"

    banner "$name"

    # Build and start
    echo "  Building..."
    dc "$scenario_dir" "$project" build 2>&1 | tail -3
    echo "  Starting..."
    dc "$scenario_dir" "$project" up -d 2>/dev/null

    if ! wait_healthy "$scenario_dir" "$project" "swerver" "curl -sSf http://localhost:8080/health" 30; then
        echo "  SKIP: swerver failed to start"
        dc "$scenario_dir" "$project" down 2>/dev/null || true
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        return
    fi

    # Special: gateway-features smoke test
    if [[ "$name" == "gateway-features" ]]; then
        echo ""
        echo "  Smoke test..."
        echo -n "    /noauth/users: "
        curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/noauth/users || echo "FAIL"
        echo -n "    /authed/users (with key): "
        curl -s -o /dev/null -w '%{http_code}\n' -H 'X-API-Key: bench-key-1' http://localhost:8080/authed/users || echo "FAIL"
    fi

    # Run all k6 tests in the scenario
    local tests
    tests=$(ls "$k6_dir"/*.js 2>/dev/null | xargs -n1 basename | sed 's/\.js$//')

    for test in $tests; do
        echo ""
        echo "--- $name / $test ---"

        local before_count
        before_count=$(ls "$suite_dir"/*.json 2>/dev/null | wc -l | tr -d ' ')

        # Special: load-balancer failover needs pause/unpause of app-3
        if [[ "$name" == "load-balancer" && "$test" == "failover" ]]; then
            echo "  (pausing app-3 at 12s, unpausing at 32s)"
            (
                sleep 12
                dc "$scenario_dir" "$project" pause app-3 2>/dev/null || true
                sleep 20
                dc "$scenario_dir" "$project" unpause app-3 2>/dev/null || true
            ) &
            local failover_pid=$!
        fi

        set +e
        docker run --rm \
            --network "$network" \
            -v "$suite_dir:/results" \
            -v "${k6_dir}:/scenarios:ro" \
            -v "$BENCH_ROOT/k6/lib:/lib:ro" \
            -e "TARGET_HOST=swerver" \
            -e "TARGET_PORT=8080" \
            "$K6_IMAGE" \
            "/scenarios/${test}.js" 2>&1 | grep -E "^(Summary| |running \()" | tail -8
        set -e

        if [[ -n "${failover_pid:-}" ]]; then
            wait "$failover_pid" 2>/dev/null || true
            unset failover_pid
        fi

        local after_count
        after_count=$(ls "$suite_dir"/*.json 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$after_count" -gt "$before_count" ]]; then
            echo "  OK"
            TOTAL_PASS=$((TOTAL_PASS + 1))
        else
            echo "  FAIL: no result file written"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
        fi
    done

    dc "$scenario_dir" "$project" down --remove-orphans 2>/dev/null || true
}

# ---- Main ----
for suite in "${SUITES[@]}"; do
    case "$suite" in
        h1) run_h1 ;;
        h2) run_h2 ;;
        h3) run_h3 ;;
        load-balancer|api-gateway|gateway-features)
            run_scenario "$suite" ;;
        *) echo "Unknown suite: $suite"; TOTAL_FAIL=$((TOTAL_FAIL + 1)) ;;
    esac
done

# ---- Report ----
banner "Results"
echo "  Directory: $RESULTS_DIR"
echo "  Passed:    $TOTAL_PASS"
echo "  Failed:    $TOTAL_FAIL"
echo ""

# Count all result files
find "$RESULTS_DIR" -name "*.json" -o -name "*.txt" | sort | while read -r f; do
    echo "  $(echo "$f" | sed "s|$RESULTS_DIR/||")"
done
echo ""

# Generate report
if command -v python3 &>/dev/null; then
    echo "Generating report..."
    python3 "$BENCH_ROOT/lib/report.py" "$RESULTS_DIR" > "$RESULTS_DIR/report.md" 2>&1 || true
    if [[ -s "$RESULTS_DIR/report.md" ]]; then
        echo ""
        cat "$RESULTS_DIR/report.md"
    fi
fi

echo "========================================"
echo "All results saved to: $RESULTS_DIR"
echo "========================================"
