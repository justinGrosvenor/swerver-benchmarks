#!/bin/bash
# Local wrk comparison of single-process HTTP servers on identical routes:
# Express, Fastify (Node), the HttpArena tuned Bun entry, and swerverts (the
# in-process libswerver / FFI backend). Each is ONE OS process so the comparison
# is apples-to-apples; per-server CPU% is sampled during the run so rps-per-core
# is visible (the JS frameworks are single-threaded ~1 core; swerverts-ffi runs
# a Zig reactor thread + a JS pump, ~1.2-1.5 cores — the rps/core column keeps
# that honest, since macOS has no way to hard-pin to one core).
#
# Usage:
#   ./bench.sh
#   SERVERS="fastify swerverts-ffi" SCENARIOS="json" DURATION=20s CONNS=128 ./bench.sh
#
# Env: SERVERS SCENARIOS DURATION CONNS THREADS WARMUP JSON_COUNT STATIC_FILE
#      SWERVER_BIN SWERVER_LIB DATASET_PATH STATIC_DIR
#   SERVERS default: express fastify bun swerverts-ffi (all single-process).
#   "swerverts" (socket backend) is available but excluded by default — it is
#   two processes (gateway + Bun app), so not comparable core-for-core.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

SERVERS="${SERVERS:-express fastify bun swerverts-ffi}"
SCENARIOS="${SCENARIOS:-pipeline baseline json static}"
DURATION="${DURATION:-10s}"
CONNS="${CONNS:-64}"
THREADS="${THREADS:-4}"
WARMUP="${WARMUP:-3}"
JSON_COUNT="${JSON_COUNT:-20}"
STATIC_FILE="${STATIC_FILE:-asset.html}"
SWERVER_BIN="${SWERVER_BIN:-$HOME/swerver/zig-out/bin/swerver}"
SWERVER_LIB="${SWERVER_LIB:-$HOME/swerver/zig-out/lib/libswerver.dylib}"
DATASET_PATH="${DATASET_PATH:-$ROOT/data/dataset.json}"
STATIC_DIR="${STATIC_DIR:-$ROOT/data/static}"

command -v wrk >/dev/null || { echo "wrk not found (brew install wrk)"; exit 1; }

STAMP="$(date +%Y%m%d_%H%M%S)"
OUTDIR="$ROOT/results/$STAMP"
mkdir -p "$OUTDIR"
SUMMARY="$OUTDIR/summary.txt"

port_for() { case "$1" in
  express) echo 3001;; fastify) echo 3003;; bun) echo 3002;;
  swerverts) echo 8080;; swerverts-ffi) echo 8081;;
esac; }

start_server() {
  # Each branch backgrounds a SIMPLE command (env + exec + redirect) so $! is
  # the actual server process, not a wrapping subshell. Backgrounding a compound
  # command (case ... &) would return the subshell pid instead — which reads 0%
  # CPU and, when killed, orphans the real server.
  local name="$1" port="$2" log="$OUTDIR/$1.server.log"
  export PORT="$port" DATASET_PATH="$DATASET_PATH" STATIC_DIR="$STATIC_DIR" SWERVER_BIN="$SWERVER_BIN" SWERVER_LIB="$SWERVER_LIB"
  case "$name" in
    express)       node servers/express.mjs >"$log" 2>&1 & ;;
    fastify)       node servers/fastify.mjs >"$log" 2>&1 & ;;
    bun)           bun servers/httparena-bun.ts >"$log" 2>&1 & ;;
    swerverts)     bun servers/swerverts-app.ts >"$log" 2>&1 & ;;
    swerverts-ffi) BACKEND=ffi bun servers/swerverts-app.ts >"$log" 2>&1 & ;;
  esac
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

row() { printf '%-14s %-8s %12s %9s %9s %7s %10s\n' "$@" | tee -a "$SUMMARY"; }

# Sample a process's total CPU% (summed across threads) every 0.25s into a file
# until killed. Runs with -e/pipefail off so a transient ps failure doesn't stop
# sampling.
sample_cpu() {
  set +e +o pipefail
  while :; do
    ps -o %cpu= -p "$1" 2>/dev/null | tr -d ' \n' >> "$2"
    printf '\n' >> "$2"
    sleep 0.25
  done
}

run_wrk() {
  local name="$1" sc="$2" port="$3" pid="$4" url out cpuf
  url="$(url_for "$port" "$sc")"
  out="$OUTDIR/${name}.${sc}.txt"
  cpuf="$OUTDIR/${name}.${sc}.cpu"
  : > "$cpuf"
  sample_cpu "$pid" "$cpuf" &
  local sampler=$!
  disown "$sampler" 2>/dev/null || true
  wrk -t"$THREADS" -c"$CONNS" -d"$DURATION" --latency "$url" >"$out" 2>&1 || true
  kill "$sampler" 2>/dev/null || true
  local rps p50 p99 cpu percore
  rps="$(awk '/Requests\/sec/{print $2}' "$out")"
  p50="$(awk '/^ *50%/{print $2; exit}' "$out")"
  p99="$(awk '/^ *99%/{print $2; exit}' "$out")"
  cpu="$(awk 'NF && $1+0>m {m=$1+0} END{ if(m>0) printf "%.0f", m; else print "NA" }' "$cpuf")"
  percore="$(awk -v r="${rps:-0}" -v c="${cpu:-0}" 'BEGIN{ if(c+0>0) printf "%.0f", r/(c/100); else print "NA" }')"
  row "$name" "$sc" "${rps:-NA}" "${p50:-NA}" "${p99:-NA}" "${cpu:-NA}" "${percore:-NA}"
}

echo "js-compare  duration=$DURATION conns=$CONNS threads=$THREADS  servers=[$SERVERS]  scenarios=[$SCENARIOS]"
echo "results -> $OUTDIR"
{
  echo "js-compare $STAMP  duration=$DURATION conns=$CONNS threads=$THREADS (all single-process)"
} | tee "$SUMMARY"
row server scenario req/sec p50 p99 cpu% rps/core
row ------ -------- ------- --- --- ---- --------

for name in $SERVERS; do
  port="$(port_for "$name")"
  pid="$(start_server "$name" "$port")"
  if ! wait_ready "$port"; then
    echo "!! $name failed to start; see $OUTDIR/$name.server.log"
    kill "$pid" 2>/dev/null || true
    continue
  fi
  wrk -t2 -c16 -d"${WARMUP}s" "http://127.0.0.1:$port/pipeline" >/dev/null 2>&1 || true
  for sc in $SCENARIOS; do run_wrk "$name" "$sc" "$port" "$pid"; done
  kill "$pid" 2>/dev/null || true
  # Hard-kill any lingering server so runs never contend (a stale server double-
  # binding the port via SO_REUSEPORT corrupts the next run).
  case "$name" in
    swerverts) pkill -f "$SWERVER_BIN" 2>/dev/null || true ;;
  esac
  [ "${name#swerverts}" != "$name" ] && { sleep 0.3; pkill -9 -f "servers/swerverts-app.ts" 2>/dev/null || true; }
  sleep 0.5
done

echo
echo "summary written to $SUMMARY"
