#!/bin/bash
# Shared functions for all benchmark scripts.
# Source this file at the top of every run script:
#   BENCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
#   source "$BENCH_ROOT/lib/common.sh"

set -euo pipefail

# Resolve BENCH_ROOT if not already set by the caller.
: "${BENCH_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ---- Swerver source sync ----
# Syncs the local swerver working copy into the Docker build context.
# Skipped unless USE_LOCAL_SWERVER=1.
sync_swerver() {
    local context="$BENCH_ROOT/servers/swerver/swerver-src"
    if [[ "${USE_LOCAL_SWERVER:-0}" == "1" ]]; then
        local src="${LOCAL_SWERVER_DIR:-$(cd "$BENCH_ROOT/.." && pwd)/swerver}"
        if [[ ! -d "$src" ]]; then
            echo "USE_LOCAL_SWERVER=1 but $src not found" >&2
            exit 1
        fi
        echo "Syncing local swerver from $src..."
        rm -rf "$context"
        mkdir -p "$context"
        rsync -a --delete \
            --exclude='.git' --exclude='.zig-cache' --exclude='zig-out' \
            "$src"/ "$context"/
    else
        rm -rf "$context"
    fi
}

# ---- Docker Compose helper ----
# Wraps docker compose with a fixed project directory and project name.
# Usage: dc <project_dir> <project_name> <compose args...>
dc() {
    local dir="$1" name="$2"
    shift 2
    docker compose --project-directory "$dir" -p "$name" "$@"
}

# ---- Wait for a service to become healthy ----
# Usage: wait_healthy <compose_project_dir> <compose_project_name> <service> <health_cmd> [timeout_s]
# health_cmd examples:
#   "curl -sSf http://localhost:8080/health"
#   "curl -sSfk https://localhost:8443/health"
wait_healthy() {
    local dir="$1" name="$2" service="$3" cmd="$4" timeout="${5:-60}"
    echo -n "  Waiting for $service..."
    for i in $(seq 1 "$timeout"); do
        if dc "$dir" "$name" exec -T "$service" sh -c "$cmd" >/dev/null 2>&1; then
            echo " ready (${i}s)"
            return 0
        fi
        echo -n "."
        sleep 1
    done
    echo " TIMEOUT"
    dc "$dir" "$name" logs "$service" 2>&1 | tail -20 || true
    return 1
}

# ---- Run a k6 test ----
# Runs k6 via `docker run`, captures JSON result from stdout delimiters.
# All results are written to $RESULTS_DIR (must be set by caller).
#
# Usage: run_k6 <network> <scenario_k6_dir> <test_name> <result_slug> [extra_env...]
# Extra env: "KEY=VALUE" pairs passed as -e flags to docker run.
#
# Returns 0 if result JSON was captured, 1 otherwise.
run_k6() {
    local network="$1" k6_dir="$2" test="$3" slug="$4"
    shift 4

    local env_flags=()
    for e in "$@"; do
        env_flags+=(-e "$e")
    done

    echo ""
    echo "--- $slug ---"

    local k6_log
    k6_log=$(mktemp)
    set +e
    docker run --rm \
        --network "$network" \
        -v "${k6_dir}:/scenarios:ro" \
        -v "$BENCH_ROOT/k6/lib:/lib:ro" \
        "${env_flags[@]}" \
        "${K6_IMAGE:-swerver-bench-k6}" \
        "/scenarios/${test}.js" > "$k6_log" 2>&1
    set -e

    # Show summary lines
    grep -E "^(Summary| |running \()" "$k6_log" | tail -8

    # Extract JSON from stdout delimiters
    local result_file="$RESULTS_DIR/${slug}.json"
    if sed -n '/__RESULT_JSON_START__/,/__RESULT_JSON_END__/p' "$k6_log" \
        | grep -v '__RESULT_JSON_' > "$result_file" 2>/dev/null \
        && [[ -s "$result_file" ]]; then
        echo "  OK: $result_file"
        rm -f "$k6_log"
        return 0
    fi

    # Fallback: check if k6 wrote to /results/ via volume mount
    rm -f "$result_file"

    # Show errors for debugging
    grep -i "level=error" "$k6_log" | tail -3 || true
    echo "  FAIL: no result captured for $slug"
    rm -f "$k6_log"
    return 1
}

# ---- Run a k6 test with volume-mount result collection ----
# For scenarios where k6 writes to /results/ inside the container.
# This mounts RESULTS_DIR as /results and expects the JS to write there.
run_k6_volume() {
    local network="$1" k6_dir="$2" test="$3" slug="$4"
    shift 4

    local env_flags=()
    for e in "$@"; do
        env_flags+=(-e "$e")
    done

    echo ""
    echo "--- $slug ---"

    set +e
    docker run --rm \
        --network "$network" \
        -v "$RESULTS_DIR:/results" \
        -v "${k6_dir}:/scenarios:ro" \
        -v "$BENCH_ROOT/k6/lib:/lib:ro" \
        "${env_flags[@]}" \
        "${K6_IMAGE:-swerver-bench-k6}" \
        "/scenarios/${test}.js" 2>&1 | grep -E "^(Summary| |running \()" | tail -8
    set -e

    # Check for result file (k6 scripts write various names)
    local found=0
    for f in "$RESULTS_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        # Only count files written in the last 30 seconds
        if [[ $(find "$f" -mmin -1 2>/dev/null) ]]; then
            found=1
        fi
    done

    if [[ $found -eq 1 ]]; then
        echo "  OK"
        return 0
    else
        echo "  FAIL: no result file written"
        return 1
    fi
}

# ---- Ensure custom k6 image is built ----
# Sets K6_IMAGE and builds if needed. The custom image has ENTRYPOINT ["k6", "run"],
# so callers pass just the script path (no `run` prefix).
ensure_k6_image() {
    K6_IMAGE="swerver-bench-k6"
    export K6_IMAGE
    if ! docker image inspect "$K6_IMAGE" >/dev/null 2>&1; then
        echo "Building k6 image..."
        docker build -t "$K6_IMAGE" "$BENCH_ROOT/k6" 2>&1 | tail -2
    fi
}

# ---- Print a section banner ----
banner() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

# ---- Ensure results directory exists ----
# Sets RESULTS_DIR to a timestamped path under $BENCH_ROOT/results/
init_results() {
    local tag="${1:-}"
    if [[ -z "${RESULTS_DIR:-}" ]]; then
        RESULTS_DIR="$BENCH_ROOT/results/$(date +%Y%m%d_%H%M%S)"
        if [[ -n "$tag" ]]; then
            RESULTS_DIR="${RESULTS_DIR}_${tag}"
        fi
    fi
    mkdir -p "$RESULTS_DIR"
    export RESULTS_DIR
}
