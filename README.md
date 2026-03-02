# Swerver Benchmarks

Reproducible HTTP server benchmarking suite for comparing [swerver](https://github.com/justinGrosvenor/swerver) against production-grade servers.

## Quick Start

```bash
# Run throughput benchmark against swerver
./scripts/run-benchmark.sh swerver

# Run all scenarios against all servers
./scripts/run-all.sh

# Compare swerver vs nginx on latency
./scripts/run-benchmark.sh swerver --scenario latency
./scripts/run-benchmark.sh nginx --scenario latency
./scripts/compare-results.py results/*.json
```

## Requirements

- Docker & Docker Compose
- ~4GB disk space for images
- ~8 min per server for default suite (~13 min with soak)
- Python 3 (optional, for comparison reports)

## Servers

| Server | Description | Status |
|--------|-------------|--------|
| swerver | Zig HTTP server (io_uring/kqueue) | Ready |
| nginx | Industry standard baseline | Ready |
| httpzig | Zig stdlib HTTP server (`http.zig`, minimal dependencies) | Ready |
| actix | Actix-web (Rust/Tokio async) | Ready |
| go-std | Go net/http | Planned |

## Benchmark Scenarios

### Core Scenarios (default)

| Scenario | Goal | Method | Duration |
|----------|------|--------|----------|
| `throughput` | Max requests/sec | GET /health, 100 VUs | 30s |
| `latency` | Response time percentiles | GET /echo, 50 VUs | 30s |
| `connections` | Connection setup overhead | GET /health, no keep-alive | 30s |
| `concurrent` | Scaling with connections | Ramp 10→1000 VUs | 150s |
| `mixed` | Realistic traffic | 30% health, 40% GET, 20% POST, 10% blob | 30s |

### Extended Scenarios (default)

| Scenario | Goal | Method | Duration |
|----------|------|--------|----------|
| `spike` | Burst traffic resilience | Ramp 50→500→50→1000→50→0 on /health | 120s |
| `payload` | Payload size scaling | 5 parallel sizes: ~0B, ~15B, 8KB, 64KB, 256KB | 30s |
| `keepalive` | Connection reuse efficiency | 50 VUs keepalive vs 50 VUs Connection: close | 30s |
| `rapid-fire` | Maximum capacity ceiling | 200 VUs, zero think time, /health | 30s |
| `error-handling` | Error path performance | 20% normal, 25% 404, 20% bad method, 20% big header, 15% bad body | 30s |

### Opt-in Scenarios

| Scenario | Goal | Method | Duration |
|----------|------|--------|----------|
| `soak` | Long-running stability | Same mix as `mixed`, 50 VUs sustained | 5 min |

## Benchmark Endpoints

All servers must implement these endpoints:

| Endpoint | Method | Response |
|----------|--------|----------|
| `/health` | GET | 200, empty body |
| `/echo` | GET | 200, `{"status":"ok"}` |
| `/echo` | POST | 200, echo request body |
| `/blob` | GET | 200, 8KB zeros |

Swerver has these built-in as of the latest version.

## Configuration

Copy `.env.example` to `.env` and modify:

```bash
# Resource limits
BENCHMARK_CPUS=2
BENCHMARK_MEMORY=512m

# Load settings
K6_VUS=100
K6_DURATION=30s

# Build specific swerver version
SWERVER_REF=v1.0.0
```

## Usage

### Single Benchmark

```bash
# Basic
./scripts/run-benchmark.sh swerver

# With options
./scripts/run-benchmark.sh nginx --scenario latency --vus 50 --duration 60s
```

### Full Suite

```bash
# All servers, all scenarios (excluding soak)
./scripts/run-all.sh

# Specific servers
./scripts/run-all.sh --servers "swerver nginx"

# Specific scenarios
./scripts/run-all.sh --scenarios "throughput latency"

# Include soak test (adds ~5 min per server)
SCENARIOS="throughput latency connections concurrent mixed spike payload keepalive rapid-fire error-handling soak" ./scripts/run-all.sh
```

### Compare Results

```bash
./scripts/compare-results.py results/*.json > comparison.md
```

### Build from Local Source

```bash
# Build swerver from local directory
./scripts/build-local.sh /path/to/swerver

# Run benchmarks against local build
docker-compose up -d swerver
./scripts/run-benchmark.sh swerver
```

## Adding a New Server

1. Create `servers/<name>/Dockerfile`
2. Implement endpoints: `/health`, `/echo`, `/blob`
3. Add service to `docker-compose.yml`
4. Update scripts if needed

See [docs/design/architecture.md](docs/design/architecture.md) for details.

## Results

### Native wrk Benchmarks

Tested on macOS (Apple Silicon), single-process, ReleaseFast build (1.8MB binary), wrk 2 threads. February 2026.

| Scenario | Connections | Requests/sec | Avg Latency | Transfer/sec |
|----------|------------|-------------|-------------|--------------|
| GET /health | 100 | **274,617** | 328us | 19.6 MB/s |
| GET /echo | 50 | **264,698** | 163us | 31.1 MB/s |
| GET /plaintext | 100 | **285,606** | 321us | 31.3 MB/s |
| GET /json | 100 | **267,543** | 335us | 34.5 MB/s |
| GET /health (high concurrency) | 500 | **268,283** | 1.80ms | 19.2 MB/s |
| GET /blob (1MB) | 50 | **6,811** | 7.35ms | 6.65 GB/s |

### Docker k6 Benchmarks

Tested on Docker Desktop (macOS, Apple Silicon) with 2 CPU cores and 512MB memory limit per container. k6 with 100 VUs, 30s duration. March 2026.

### Throughput (GET /health, 100 VUs, 30s)

Maximum requests per second on minimal endpoint.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **actix** | 157,165 | 1.13 ms | 2.01 ms | 0% |
| **swerver** | 152,617 | 1.11 ms | 2.18 ms | 0% |
| **nginx** | 120,435 | 1.54 ms | 2.66 ms | 0% |
| http-zig | 108,160 | 1.15 ms | 2.10 ms | 0% |

### Latency (GET /echo with JSON, 100 VUs, 30s)

Response time percentiles with JSON payload.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **nginx** | 8,251 | 2.88 ms | 4.46 ms | 0% |
| actix | 7,901 | 2.87 ms | 4.66 ms | 0% |
| **swerver** | 7,882 | 3.00 ms | 4.46 ms | 0% |
| http-zig | 5,306 | 2.61 ms | 5.05 ms | 0% |

### Connections (No keep-alive, 100 VUs, 30s)

Connection setup overhead - new TCP connection per request.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **swerver** | 90,091 | 1.51 ms | 2.83 ms | 0% |
| actix | 71,610 | 2.23 ms | 7.30 ms | 0% |
| http-zig | 31,244 | 5.50 ms | 63.28 ms | 0% |
| nginx | 25,167 | 11.67 ms | 27.95 ms | 0% |

### Concurrent (Ramp 10→1000 VUs, 30s)

Scaling with increasing connections.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **swerver** | 149,798 | 3.59 ms | 5.51 ms | 0% |
| actix | 141,147 | 3.74 ms | 5.64 ms | 0% |
| http-zig | 125,998 | 1.07 ms | 2.06 ms | 0% |
| nginx | 117,638 | 4.52 ms | 7.49 ms | 0% |

### Mixed Workload (30% health, 40% GET, 20% POST, 10% blob)

Realistic traffic pattern with varied request types.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **swerver** | 38,163 | 4.19 ms | 9.59 ms | 0% |
| actix | 36,701 | 4.13 ms | 9.99 ms | 0% |
| nginx | 30,593 | 4.98 ms | 13.78 ms | 0% |
| http-zig | 7,451 | 41.56 ms | 43.52 ms | 0% |

### Spike (50→500→1000 VUs, 120s)

Server resilience under sudden traffic bursts.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **swerver** | 157,534 | 2.61 ms | 4.24 ms | 0% |
| httpzig | 134,784 | 0.84 ms | 1.58 ms | 0% |
| actix | 124,529 | 3.41 ms | 5.54 ms | 0% |
| nginx | 111,009 | 3.48 ms | 5.68 ms | 0% |

### Payload Size Scaling (5 sizes, 20 VUs each, 30s)

Performance across payload sizes from ~0B to 256KB.

| Server | Total RPS | Tiny (~0B) | Small (~15B) | Medium (8KB) | Large (64KB) | XLarge (256KB) |
|--------|-----------|------------|--------------|---------------|---------------|----------------|
| http-zig | 105,896 | 22,429 | 26,219 | 30,348 | 27,021 | 3 |
| actix | 85,095 | 19,620 | 19,538 | 18,469 | 15,255 | 12,216 |
| **swerver** | 62,892 | 14,446 | 14,316 | 13,440 | 10,564 | 10,130 |
| nginx | 43,648 | 9,998 | 9,964 | 9,275 | 7,592 | 6,822 |

### Keepalive Efficiency (50 VUs per mode, 30s)

Throughput gain from HTTP connection reuse.

| Server | Keepalive RPS | No-Keepalive RPS | Efficiency Gain | p99 Latency |
|--------|--------------|------------------|-----------------|-------------|
| **swerver** | 101,331 | 35,218 | +188% | 2.69 ms |
| actix | 81,125 | 33,905 | +139% | 3.04 ms |
| http-zig | 80,244 | 27,729 | +189% | 3.18 ms |
| nginx | 58,938 | 21,510 | +174% | 7.03 ms |

### Rapid-Fire (200 VUs, zero think time, 30s)

Maximum capacity ceiling on minimal endpoint.

| Server | Requests/sec | p95 Latency | p99 Latency | p99.9 Latency | Timeouts |
|--------|-------------|-------------|-------------|---------------|----------|
| **swerver** | 148,720 | 1.03 ms | 1.97 ms | 4.87 ms | 0% |
| nginx | 122,923 | 1.20 ms | 2.06 ms | 3.84 ms | 0% |
| actix | 122,055 | 1.37 ms | 2.52 ms | 4.82 ms | 0% |
| http-zig | 113,425 | 1.07 ms | 1.91 ms | 3.50 ms | 0% |

### Error Handling (100 VUs, 30s)

Error path performance (404s, wrong method, oversized headers, bad bodies).

| Server | Requests/sec | p95 Latency | p99 Latency | Correct Status |
|--------|-------------|-------------|-------------|----------------|
| actix | 170,825 | 1.19 ms | 2.06 ms | 100% |
| **swerver** | 124,693 | 0.99 ms | 1.96 ms | 100% |
| nginx | 79,919 | 2.10 ms | 27.16 ms | 100% |
| http-zig | 2,417 | 43.57 ms | 55.63 ms | 80% |

---

### Key Findings

**Native performance (wrk, single process):**
- **285K req/s** on plaintext — saturates single-core kqueue event loop
- **Sub-millisecond latency** across all endpoints at 100 connections
- **6.65 GB/s** throughput on large responses (1MB blob)
- Stable under high concurrency (500 connections, <2ms avg latency)

**Docker comparison (k6, containerized) — swerver wins 7/10 scenarios:**
- **Throughput**: 153K req/s — neck-and-neck with actix (157K), 27% faster than nginx
- **Connection handling**: 3.6x faster than nginx at new connections (90K vs 25K conn/s)
- **Concurrent scaling**: Best throughput at 1000 VUs (150K req/s), beats actix by 6%
- **Mixed workload**: 38.2K req/s — beats actix (36.7K) and nginx (30.6K) with 0% errors
- **Spike resilience**: 158K req/s through 1000 VU spikes, 0% errors, 27% faster than actix
- **Keepalive efficiency**: 188% throughput gain from connection reuse (101K vs 35K rps)
- **Rapid-fire**: 149K req/s ceiling — 22% faster than actix and nginx
- **Payload scaling**: 10.6K req/s at 64KB, 10.1K req/s at 256KB — consistent across sizes
- **Error handling**: 125K req/s on error paths with 100% correct status codes, best p99 latency
- **Latency**: Tied with nginx for best p99 on echo (4.46ms), sub-2ms p99 on throughput

**vs other Zig (http-zig):**
- 1.4x faster throughput, 2.9x faster connection setup, 5x faster mixed workload
- http-zig wins on payload (thread-per-connection avoids event loop overhead for large bodies)

Results are saved to `results/` as JSON:

```json
{
  "scenario": "throughput",
  "server": "swerver",
  "metrics": {
    "requests_per_second": 45000,
    "latency_p99_ms": 5.2,
    "error_rate": 0
  }
}
```

## Tips for Accurate Benchmarks

1. **Dedicated machine** - No other workloads
2. **Disable CPU scaling** - `cpupower frequency-set -g performance`
3. **Multiple runs** - Report median of 3+ runs
4. **Warm up** - Discard first run
5. **Same resources** - All servers get same CPU/memory limits
