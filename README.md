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

Tested on Docker Desktop (macOS, Apple Silicon) with 2 CPU cores and 512MB memory limit per container. k6 with 100 VUs, 30s duration. February 2026.

### Throughput (GET /health, 100 VUs, 30s)

Maximum requests per second on minimal endpoint.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **swerver** | 168,588 | 1.01 ms | 1.93 ms | 0% |
| **actix** | 129,903 | 1.45 ms | 2.72 ms | 0% |
| http-zig | 122,597 | 1.13 ms | 2.05 ms | 0% |
| **nginx** | 121,745 | 1.53 ms | 2.67 ms | 0% |

### Latency (GET /echo with JSON, 100 VUs, 30s)

Response time percentiles with JSON payload.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **nginx** | 8,171 | 3.19 ms | 5.18 ms | 0% |
| **swerver** | 7,979 | 2.81 ms | 5.02 ms | 0% |
| actix | 7,642 | 3.05 ms | 5.52 ms | 0% |
| http-zig | 5,292 | 2.66 ms | 5.06 ms | 0% |

### Connections (No keep-alive, 100 VUs, 30s)

Connection setup overhead - new TCP connection per request.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **swerver** | 86,971 | 1.78 ms | 3.24 ms | 0% |
| **actix** | 64,733 | 2.31 ms | 9.19 ms | 0% |
| http-zig | 24,692 | 7.14 ms | 72.46 ms | 0% |
| nginx | 23,928 | 12.65 ms | 28.68 ms | 0% |

### Concurrent (Ramp 10→1000 VUs, 30s)

Scaling with increasing connections.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **swerver** | 196,990 | 0.95 ms | 1.79 ms | 0% |
| **actix** | 159,399 | 1.29 ms | 2.32 ms | 0% |
| http-zig | 133,499 | 1.10 ms | 2.01 ms | 0% |
| **nginx** | 132,025 | 1.54 ms | 2.66 ms | 0% |

### Mixed Workload (30% health, 40% GET, 20% POST, 10% blob)

Realistic traffic pattern with varied request types.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **swerver** | 36,405 | 3.67 ms | 8.94 ms | 0% |
| **actix** | 35,970 | 4.04 ms | 10.06 ms | 0% |
| **nginx** | 34,781 | 4.12 ms | 11.81 ms | 0% |
| http-zig | 7,544 | 41.23 ms | 42.08 ms | 0% |

### Spike (50→500→1000 VUs, 120s)

Server resilience under sudden traffic bursts.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **swerver** | 172,617 | 0.95 ms | 1.78 ms | 0% |

### Payload Size Scaling (5 sizes, 20 VUs each, 30s)

Performance across payload sizes from ~0B to 256KB.

| Server | Total RPS | Tiny (~0B) | Small (~15B) | Medium (8KB) | Large (64KB) | XLarge (256KB) |
|--------|-----------|------------|--------------|---------------|---------------|----------------|
| **swerver** | 154,888 | 51,758 | 51,262 | 52,043 | 2 | 2 |

### Keepalive Efficiency (50 VUs per mode, 30s)

Throughput gain from HTTP connection reuse.

| Server | Keepalive RPS | No-Keepalive RPS | Efficiency Gain | p99 Latency |
|--------|--------------|------------------|-----------------|-------------|
| **swerver** | 97,227 | 35,642 | +173% | 2.72 ms |

### Rapid-Fire (200 VUs, zero think time, 30s)

Maximum capacity ceiling on minimal endpoint.

| Server | Requests/sec | p95 Latency | p99 Latency | p99.9 Latency | Timeouts |
|--------|-------------|-------------|-------------|---------------|----------|
| **swerver** | 124,899 | 1.31 ms | 2.65 ms | 9.36 ms | 0% |

### Error Handling (100 VUs, 30s)

Error path performance (404s, wrong method, oversized headers, bad bodies).

| Server | Requests/sec | p95 Latency | p99 Latency | Correct Status |
|--------|-------------|-------------|-------------|----------------|
| **swerver** | 165,132 | 0.95 ms | 1.99 ms | 100% |

---

### Key Findings

**Native performance (wrk, single process):**
- **285K req/s** on plaintext — saturates single-core kqueue event loop
- **Sub-millisecond latency** across all endpoints at 100 connections
- **6.65 GB/s** throughput on large responses (1MB blob)
- Stable under high concurrency (500 connections, <2ms avg latency)

**Docker comparison (k6, containerized):**
- **Throughput**: 169K req/s — 30% faster than actix, 38% faster than nginx
- **Connection handling**: 3.6x faster than nginx at new connections (87K vs 24K conn/s)
- **Concurrent scaling**: Best throughput at 1000 VUs (197K req/s) with lowest p99 (1.79ms)
- **Mixed workload**: Wins all scenarios after blob size fix — 36K req/s with lowest p99 (8.94ms)
- **Low latency**: Sub-2ms p99 on throughput and concurrent scenarios
- **Spike resilience**: 0% errors through 1000 VU spikes, p99 stays under 2ms
- **Keepalive efficiency**: 173% throughput gain from connection reuse (97K vs 36K rps)
- **Error handling**: 165K req/s on error paths with 100% correct status codes

**vs other Zig (http-zig):**
- 1.4x faster throughput, 3.5x faster connection setup
- Both use fixed thread pools; swerver's event loop avoids per-connection blocking

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
