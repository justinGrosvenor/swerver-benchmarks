#!/bin/bash
# Run all benchmark scenarios against all servers
# Usage: ./run-all.sh [--servers "swerver nginx"] [--scenarios "throughput latency"]

set -e

cd "$(dirname "$0")/.."

# Defaults
SERVERS="${SERVERS:-swerver nginx httpzig actix}"
SCENARIOS="${SCENARIOS:-throughput latency connections concurrent mixed}"
VUS="${K6_VUS:-100}"
DURATION="${K6_DURATION:-30s}"

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --servers)
            SERVERS="$2"
            shift 2
            ;;
        --scenarios)
            SCENARIOS="$2"
            shift 2
            ;;
        --vus)
            VUS="$2"
            shift 2
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "========================================"
echo "Full Benchmark Suite"
echo "========================================"
echo "Servers:   $SERVERS"
echo "Scenarios: $SCENARIOS"
echo "VUs:       $VUS"
echo "Duration:  $DURATION"
echo "========================================"
echo ""

# Sync local swerver sources if available
LOCAL_SWERVER_DIR="$(cd .. && pwd)/swerver"
LOCAL_SWERVER_CONTEXT="./servers/swerver/swerver-src"
if [[ -d "$LOCAL_SWERVER_DIR" ]]; then
    echo "Syncing local swerver sources into Docker context..."
    rm -rf "$LOCAL_SWERVER_CONTEXT"
    mkdir -p "$LOCAL_SWERVER_CONTEXT"
    rsync -a --delete --exclude='.git' --exclude='.zig-cache' --exclude='zig-out' "$LOCAL_SWERVER_DIR"/ "$LOCAL_SWERVER_CONTEXT"/
fi

# Track results
RESULTS_DIR="results/run_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

# Clean any leftover result files from previous runs
for sc in $SCENARIOS; do
    rm -f "results/${sc}.json"
done

# Build all servers first
echo "Building all servers..."
docker-compose build $SERVERS

# Run benchmarks
for server in $SERVERS; do
    echo ""
    echo "========================================"
    echo "Testing: $server"
    echo "========================================"

    # Start server
    echo "Starting $server..."
    docker-compose up -d "$server"

    # Wait for ready (try curl first, fall back to wget)
    for i in {1..30}; do
        if docker-compose exec -T "$server" curl -sSf "http://localhost:8080/health" 2>/dev/null; then
            break
        elif docker-compose exec -T "$server" wget -q --spider "http://localhost:8080/health" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    for scenario in $SCENARIOS; do
        echo ""
        echo "--- $server / $scenario ---"
        if [[ "$scenario" == "concurrent" ]]; then
            echo "Note: concurrent scenario ignores --duration/K6_DURATION; using fixed ramp stages."
        fi

        # Determine port based on server
        case $server in
            swerver) TARGET_PORT=8080 ;;
            nginx) TARGET_PORT=8080 ;;
            *) TARGET_PORT=8080 ;;
        esac

        # Remove stale result file to prevent attributing previous server's data
        rm -f "results/${scenario}.json"

        # Run benchmark (explicit volume mount for results)
        docker-compose run --rm \
            -v "$(pwd)/results:/results" \
            -e K6_VUS="$VUS" \
            -e K6_DURATION="$DURATION" \
            -e TARGET_HOST="$server" \
            -e TARGET_PORT="$TARGET_PORT" \
            k6 "/scenarios/${scenario}.js" || true

        # Move results
        if [[ -f "results/${scenario}.json" ]]; then
            mv "results/${scenario}.json" "$RESULTS_DIR/${server}_${scenario}.json"
        fi
    done

    # Stop server
    docker-compose stop "$server"
done

# Clean up
docker-compose down

echo ""
echo "========================================"
echo "All benchmarks complete!"
echo "Results saved to: $RESULTS_DIR/"
echo "========================================"

# Generate comparison if Python available
if command -v python3 &> /dev/null; then
    echo ""
    echo "Generating comparison report..."
    ./scripts/compare-results.py "$RESULTS_DIR"/*.json > "$RESULTS_DIR/comparison.md"
    echo "Report saved to: $RESULTS_DIR/comparison.md"
fi
