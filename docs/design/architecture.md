# Swerver Benchmarks - Architecture

## Overview

A reproducible HTTP server benchmarking suite for comparing swerver against production-grade servers. Uses Docker for isolation and k6 for load generation.

## Goals

1. **Reproducible** - Same results on any machine with Docker
2. **Fair** - All servers run with equivalent resources and configuration
3. **Comprehensive** - Test throughput, latency, connection handling, and edge cases
4. **Extensible** - Easy to add new competitors
5. **Automated** - Single command to run full benchmark suite

## Non-Goals

- Benchmarking TLS performance (separate concern)
- Testing application logic (we test HTTP layer only)
- Micro-optimizing k6 scripts (focus on realistic workloads)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Docker Network                          │
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   swerver   │    │    nginx    │    │  [future]   │     │
│  │   :8080     │    │   :8081     │    │   :8082+    │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
│         │                 │                  │              │
│         └────────────────┼──────────────────┘              │
│                          │                                  │
│                   ┌──────▼──────┐                          │
│                   │     k6      │                          │
│                   │  (loader)   │                          │
│                   └──────┬──────┘                          │
│                          │                                  │
│                   ┌──────▼──────┐                          │
│                   │ prometheus  │  (optional)              │
│                   │  + grafana  │                          │
│                   └─────────────┘                          │
└─────────────────────────────────────────────────────────────┘
```

---

## Servers

### Current

| Server  | Port | Description |
|---------|------|-------------|
| swerver | 8080 | Target server (Zig, io_uring/kqueue) |
| nginx   | 8081 | Industry standard baseline |

### Planned

| Server    | Port | Description |
|-----------|------|-------------|
| httpzig   | 8082 | Zig standard library HTTP server (`http.zig`, minimal-dependency baseline) |
| actix     | 8083 | Actix-web (one of the fastest Rust async frameworks, used as the primary Rust comparison) |
| go-std    | 8084 | Go net/http (common baseline) |
| drogon    | 8085 | C++ (extreme performance) |
| hyper     | 8086 | Rust (widely used) |

This benchmark suite now tracks both `httpzig` (the `http.zig` reference server) and Actix-web so we can compare Swerver against the fastest Zig and Rust production servers as part of the spec.

---

## Benchmark Scenarios

### 1. Throughput (`throughput.js`)
- **Goal**: Maximum requests/second
- **Method**: GET /health (minimal response)
- **Config**: 100 VUs, 30s duration, no think time
- **Metrics**: req/s, errors

### 2. Latency Distribution (`latency.js`)
- **Goal**: Response time percentiles under load
- **Method**: GET /echo (small JSON response)
- **Config**: 50 VUs, 60s duration
- **Metrics**: p50, p90, p95, p99, max

### 3. Connection Handling (`connections.js`)
- **Goal**: Test connection setup/teardown overhead
- **Method**: GET /health with `Connection: close`
- **Config**: 100 VUs, 30s, new connection per request
- **Metrics**: req/s, connection errors

### 4. Keep-Alive Efficiency (`keepalive.js`)
- **Goal**: Test connection reuse
- **Method**: GET /health, 100 requests per connection
- **Config**: 50 VUs, 60s
- **Metrics**: req/s improvement over connections.js

### 5. Large Response (`large-response.js`)
- **Goal**: Test I/O and buffering efficiency
- **Method**: GET /blob (1MB response)
- **Config**: 20 VUs, 30s
- **Metrics**: throughput (MB/s), latency

### 6. POST Body Handling (`post-body.js`)
- **Goal**: Test request body parsing
- **Method**: POST /echo with 1KB JSON body
- **Config**: 50 VUs, 30s
- **Metrics**: req/s, latency

### 7. Concurrent Connections (`concurrent.js`)
- **Goal**: Test scalability with many connections
- **Method**: GET /health
- **Config**: Ramp 10 → 500 → 1000 VUs over 60s
- **Metrics**: req/s at each level, error rate

### 8. Mixed Workload (`mixed.js`)
- **Goal**: Realistic traffic pattern
- **Method**: 70% GET, 20% POST, 10% large response
- **Config**: 100 VUs, 120s
- **Metrics**: aggregate req/s, latency by endpoint

---

## Server Configuration Principles

All servers configured for **fair comparison**:

1. **Same resource limits**: 2 CPU, 512MB RAM (configurable)
2. **Same worker model**: Match worker count to CPU limit
3. **Same keep-alive**: 75s timeout, 1000 max requests
4. **Same logging**: Disabled (no I/O overhead)
5. **Same response**: Identical payloads for each endpoint

### Required Endpoints

Each server must implement:

| Endpoint | Method | Response |
|----------|--------|----------|
| `/health` | GET | `200 OK`, empty body |
| `/echo` | GET | `200 OK`, `{"status":"ok"}` |
| `/echo` | POST | `200 OK`, echo request body |
| `/blob` | GET | `200 OK`, 1MB of zeros |

---

## Results Format

Results stored in `results/` as JSON:

```json
{
  "timestamp": "2025-01-11T10:30:00Z",
  "scenario": "throughput",
  "server": "swerver",
  "git_ref": "abc123",
  "config": {
    "vus": 100,
    "duration": "30s",
    "cpus": 2,
    "memory": "512m"
  },
  "metrics": {
    "requests_total": 450000,
    "requests_per_second": 15000,
    "errors_total": 0,
    "latency_p50_ms": 2.1,
    "latency_p95_ms": 5.3,
    "latency_p99_ms": 12.4
  }
}
```

---

## Adding a New Competitor

1. Create `servers/<name>/Dockerfile`
2. Create `servers/<name>/config/` with server config
3. Create `servers/<name>/app/` with endpoint implementations (if needed)
4. Add service to `docker-compose.yml`
5. Add to `SERVERS` list in `scripts/run-benchmark.sh`
6. Run `./scripts/run-benchmark.sh <name>` to verify

### Dockerfile Template

```dockerfile
FROM <base-image>

# Install/build server
RUN ...

# Copy config
COPY config/ /etc/<server>/

# Copy app code (if applicable)
COPY app/ /app/

EXPOSE 8080
CMD ["<server-binary>", "<args>"]
```

---

## Directory Structure

```
swerver-benchmarks/
├── docs/
│   └── design/
│       └── architecture.md
├── servers/
│   ├── swerver/
│   │   ├── Dockerfile
│   │   └── app/
│   │       └── main.zig          # benchmark endpoints
│   ├── nginx/
│   │   ├── Dockerfile
│   │   └── config/
│   │       └── nginx.conf
│   └── <future>/
├── k6/
│   ├── Dockerfile
│   ├── scenarios/
│   │   ├── throughput.js
│   │   ├── latency.js
│   │   ├── connections.js
│   │   ├── keepalive.js
│   │   ├── large-response.js
│   │   ├── post-body.js
│   │   ├── concurrent.js
│   │   └── mixed.js
│   └── lib/
│       └── helpers.js            # shared utilities
├── scripts/
│   ├── run-benchmark.sh          # main entrypoint
│   ├── run-all.sh                # run all servers
│   └── compare-results.py        # generate comparison report
├── results/                      # gitignored
│   └── .gitkeep
├── docker-compose.yml
├── .env.example
└── README.md
```

---

## Usage

```bash
# Run single server benchmark
./scripts/run-benchmark.sh swerver

# Run all servers
./scripts/run-all.sh

# Run specific scenario
./scripts/run-benchmark.sh swerver --scenario throughput

# Build specific swerver version
docker-compose build --build-arg SWERVER_REF=v1.0.0 swerver

# Generate comparison report
./scripts/compare-results.py results/*.json > report.md
```

---

## Resource Configuration

Default limits (override via `.env`):

```bash
BENCHMARK_CPUS=2
BENCHMARK_MEMORY=512m
K6_VUS=100
K6_DURATION=30s
```

For production benchmarks, recommend:
- Dedicated machine (no other workloads)
- Disable CPU frequency scaling
- Use `--cpuset-cpus` for pinning
- Run multiple iterations, report median
