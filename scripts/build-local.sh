#!/bin/bash
# Build swerver from local source for benchmarking
# Usage: ./build-local.sh /path/to/swerver

set -e

SWERVER_PATH="${1:-../swerver}"

if [[ ! -d "$SWERVER_PATH" ]]; then
    echo "Error: swerver directory not found at $SWERVER_PATH"
    echo "Usage: ./build-local.sh /path/to/swerver"
    exit 1
fi

cd "$(dirname "$0")/.."

echo "Building swerver from local source: $SWERVER_PATH"

# Create temporary directory for Docker context
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Copy swerver source to temp dir
cp -r "$SWERVER_PATH" "$TEMP_DIR/swerver-src"

# Copy Dockerfile
cp servers/swerver/Dockerfile "$TEMP_DIR/"

# Build from temp context
docker build \
    -t swerver-bench:local \
    -f "$TEMP_DIR/Dockerfile" \
    "$TEMP_DIR"

echo ""
echo "Built swerver-bench:local"
echo "Run with: docker run -p 8080:8080 swerver-bench:local"
