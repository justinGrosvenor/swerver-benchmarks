# js-compare: swerverts vs Express vs the HttpArena Bun entry

A small, local benchmark comparing three ways to serve the same routes:

- **express** - Express 5 on Node (one hop, one process)
- **bun** - HttpArena's canonical tuned Bun entry (`Bun.serve`, one process here;
  the real entry runs one per core with `reusePort`). Vendored from
  `HttpArena/frameworks/bun/server.ts` and parameterized for local runs.
- **swerverts** - swerver (Zig) as the front process, with the dynamic handlers
  running in a Bun server on a unix socket that swerver proxies to

It uses [`wrk`](https://github.com/wg/wrk) (not the repo's k6/Docker harness) so
it runs on a laptop with no containers: `brew install wrk`.

## Routes (HttpArena vocabulary, identical across all three)

| scenario | request | notes |
| --- | --- | --- |
| `pipeline` | `GET /pipeline` -> `ok` | cheapest possible route; measures the hop |
| `baseline` | `GET /baseline11?a=1&b=2&c=3` -> sum | tiny text, query parsing |
| `json` | `GET /json/20` -> 20 items from the dataset | JSON serialization |
| `static` | `GET /static/asset.html` (~1KB) | swerver serves `/static/` natively; Express/Bun from the runtime |

Data lives in `data/` (`dataset.json`, `static/asset.html`), generated once and
committed so runs are reproducible.

## Run

```sh
bun install                     # links ../../swerverts and installs express
export SWERVER_BIN=~/swerver/zig-out/bin/swerver
./bench.sh                      # all servers, all scenarios
SERVERS="bun swerverts" SCENARIOS="json" DURATION=20s CONNS=128 ./bench.sh
```

Results (raw `wrk` output plus a `summary.txt`) land in `results/<timestamp>/`.
Env knobs: `SERVERS`, `SCENARIOS`, `DURATION`, `CONNS`, `THREADS`, `WARMUP`,
`JSON_COUNT`, `STATIC_FILE`, `SWERVER_BIN`.

## Reading the numbers fairly

- swerverts routes a **dynamic** request through two hops (client -> swerver ->
  unix socket -> Bun handler); Express and the Bun entry are one hop. The `bun`
  entry is the reference for what that same handler runtime does without the
  gateway in front, so `pipeline`/`baseline`/`json` show the cost of the proxy
  hop, not a runtime difference.
- `static` is the opposite: swerver serves the `/static/` prefix in Zig
  (precompression, caching, sendfile paths) while Express/Bun read a file per
  request in the runtime.
- The single-process, single-worker setup here is a **latency-bound** laptop
  test. It is not the HttpArena result: that runs one process per core with
  `reusePort`, pinned CPUs, and longer durations. Treat these as directional.
- Where swerverts is meant to win is everything that never crosses into TS -
  TLS, HTTP/2, HTTP/3/QUIC, the reverse proxy, rate limiting, auth, gateway
  features - none of which this JSON-route microbenchmark exercises.

To push swerverts on the dynamic routes, raise `CONNS` and set more swerver
workers (edit `swerverts-app.ts` to pass `workers`) so multiple swerver workers
fan out to the app socket; the single Bun app server is still the ceiling.
