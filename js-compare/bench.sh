#!/bin/bash
# Local wrk comparison of Express (Node), swerverts (swerver+Bun), and a pure
# Bun.serve baseline on identical routes.
#
# Usage:
#   ./bench.sh                       # all servers, json + static scenarios
#   SERVERS="express swerverts" ./bench.sh
#   SCENARIOS="json" DURATION=20s CONNS=128 ./bench.sh
#
# Env:
#   SERVERS     space-separated: express bun swerverts   (default: all three)
#   SCENARIOS   space-separated: json static echo        (default: json static)
#   DURATION    wrk duration            (default 10s)
#   CONNS       wrk connections         (default 64)
#   THREADS     wrk threads             (default 4)
#   WARMUP      warmup seconds          (default 3)
#   SWERVER_BIN path to swerver binary  (default ~/swerver/zig-out/bin/swerver)
#
# Note: swerverts routes a dynamic request through swerver AND a unix-socket hop
# to the Bun handler (two hops); Express and the Bun baseline are one hop. Read
# the json numbers with that in mind, and the static numbers as swerver serving
# a file natively vs a JS runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

SERVERS="${SERVERS:-express bun swerverts}"
SCENARIOS="${SCENARIOS:-pipeline baseline json static}"
DURATION="${DURATION:-10s}"
CONNS="${CONNS:-64}"
THREADS="${THREADS:-4}"
WARMUP="${WARMUP:-3}"
JSON_COUNT="${JSON_COUNT:-20}"
STATIC_FILE="${STATIC_FILE:-asset.html}"
SWERVER_BIN="${SWERVER_BIN:-$HOME/swerver/zig-out/bin/swerver}"
DATASET_PATH="${DATASET_PATH:-$ROOT/data/dataset.json}"
STATIC_DIR="${STATIC_DIR:-$ROOT/data/static}"

command -v wrk >/dev/null || { echo "wrk not found (brew install wrk)"; exit 1; }

STAMP="$(date +%Y%m%d_%H%M%S)"
OUTDIR="$ROOT/results/$STAMP"
mkdir -p "$OUTDIR"
SUMMARY="$OUTDIR/summary.txt"

# "bun" is the vendored HttpArena tuned Bun entry.
port_for() { case "$1" in express) echo 3001;; bun) echo 3002;; swerverts) echo 8080;; esac; }

start_server() {
  local name="$1" port="$2"
  case "$name" in
    express)   PORT="$port" DATASET_PATH="$DATASET_PATH" STATIC_DIR="$STATIC_DIR" node servers/express.mjs ;;
    bun)       PORT="$port" DATASET_PATH="$DATASET_PATH" STATIC_DIR="$STATIC_DIR" bun run servers/httparena-bun.ts ;;
    swerverts) SWERVER_BIN="$SWERVER_BIN" PORT="$port" DATASET_PATH="$DATASET_PATH" STATIC_DIR="$STATIC_DIR" bun run servers/swerverts-app.ts ;;
  esac >"$OUTDIR/$name.server.log" 2>&1 &
  echo $!
}

wait_ready() {
  local port="$1" i
  for i in $(seq 1 100); do
    if curl -fs "http://127.0.0.1:$port/pipeline" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
  done
  return 1
}

url_for() { local port="$1" sc="$2"
  case "$sc" in
    pipeline) echo "http://127.0.0.1:$port/pipeline" ;;
    baseline) echo "http://127.0.0.1:$port/baseline11?a=1&b=2&c=3" ;;
    json)     echo "http://127.0.0.1:$port/json/$JSON_COUNT" ;;
    static)   echo "http://127.0.0.1:$port/static/$STATIC_FILE" ;;
  esac
}

run_wrk() {
  local name="$1" sc="$2" port="$3" url out extra=()
  url="$(url_for "$port" "$sc")"
  out="$OUTDIR/${name}.${sc}.txt"
  wrk -t"$THREADS" -c"$CONNS" -d"$DURATION" --latency ${extra[@]+"${extra[@]}"} "$url" >"$out" 2>&1 || true
  local rps p50 p99
  rps="$(awk '/Requests\/sec/{print $2}' "$out")"
  p50="$(awk '/^ *50%/{print $2; exit}' "$out")"
  p99="$(awk '/^ *99%/{print $2; exit}' "$out")"
  printf '%-11s %-7s %14s  %9s  %9s\n' "$name" "$sc" "${rps:-NA}" "${p50:-NA}" "${p99:-NA}" | tee -a "$SUMMARY"
}

echo "js-compare  duration=$DURATION conns=$CONNS threads=$THREADS  servers=[$SERVERS]  scenarios=[$SCENARIOS]"
echo "results -> $OUTDIR"
{
  echo "js-compare $STAMP  duration=$DURATION conns=$CONNS threads=$THREADS"
  printf '%-11s %-7s %14s  %9s  %9s\n' "server" "scenario" "req/sec" "p50" "p99"
  printf '%-11s %-7s %14s  %9s  %9s\n' "------" "--------" "-------" "---" "---"
} | tee "$SUMMARY"

for name in $SERVERS; do
  port="$(port_for "$name")"
  pid="$(start_server "$name" "$port")"
  if ! wait_ready "$port"; then
    echo "!! $name failed to start; see $OUTDIR/$name.server.log"
    kill "$pid" 2>/dev/null || true
    continue
  fi
  # Warmup
  wrk -t2 -c16 -d"${WARMUP}s" "http://127.0.0.1:$port/pipeline" >/dev/null 2>&1 || true
  for sc in $SCENARIOS; do run_wrk "$name" "$sc" "$port"; done
  kill "$pid" 2>/dev/null || true
  [ "$name" = "swerverts" ] && pkill -f "$SWERVER_BIN" 2>/dev/null || true
  sleep 0.5
done

echo
echo "summary written to $SUMMARY"
