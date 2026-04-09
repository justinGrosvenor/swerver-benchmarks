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
| apisix | Apache APISIX (nginx + LuaJIT gateway) | Ready |
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

Tested on Docker Desktop (macOS, Apple Silicon) with 2 CPU cores and 512MB memory limit per container. k6 with 100 VUs, 30s duration. April 2026.

### Throughput (GET /health, 100 VUs, 30s)

Maximum requests per second on minimal endpoint.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **swerver** | 147,435 | 1.18 ms | 2.21 ms | 0% |
| actix | 133,691 | 1.39 ms | 2.50 ms | 0% |
| nginx | 118,061 | 1.58 ms | 2.72 ms | 0% |
| http-zig | 106,937 | 0.94 ms | 1.66 ms | 0% |
| apisix | 91,522 | 1.69 ms | 18.41 ms | 0% |

### Latency (GET /echo with JSON, 50 VUs, 30s)

Response time percentiles with JSON payload under moderate load.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| nginx | 8,659 | 1.55 ms | 3.19 ms | 0% |
| apisix | 8,645 | 1.65 ms | 3.34 ms | 0% |
| actix | 8,638 | 1.70 ms | 3.04 ms | 0% |
| **swerver** | 8,517 | 1.88 ms | 3.29 ms | 0% |
| http-zig | 5,539 | 1.36 ms | 2.90 ms | 0.06% |

### Connections (No keep-alive, 100 VUs, 30s)

Connection setup overhead - new TCP connection per request.

| Server | Connections/sec | p95 Latency | p99 Latency | Errors |
|--------|-----------------|-------------|-------------|--------|
| **swerver** | 90,657 | 1.64 ms | 2.83 ms | 0% |
| actix | 66,019 | 2.32 ms | 9.21 ms | 0% |
| http-zig | 29,140 | 6.16 ms | 61.64 ms | 0% |
| apisix | 22,916 | 13.54 ms | 37.68 ms | 0% |
| nginx | 19,206 | 15.38 ms | 33.46 ms | 0% |

### Concurrent (Ramp 10→1000 VUs, 150s)

Scaling with increasing connections.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **swerver** | 156,854 | 3.39 ms | 5.20 ms | 0% |
| actix | 149,558 | 3.39 ms | 5.11 ms | 0% |
| http-zig | 130,749 | 1.02 ms | 1.91 ms | 0.03% |
| nginx | 120,577 | 4.30 ms | 6.62 ms | 0% |
| apisix | 92,751 | 10.52 ms | 30.66 ms | 0% |

### Mixed Workload (30% health, 40% GET, 20% POST, 10% blob, 100 VUs, 30s)

Realistic traffic pattern with varied request types.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| nginx | 36,969 | 4.19 ms | 10.25 ms | 0% |
| **swerver** | 36,929 | 4.15 ms | 9.62 ms | 0% |
| actix | 36,661 | 4.09 ms | 10.13 ms | 0% |
| apisix | 35,378 | 4.30 ms | 11.09 ms | 0% |
| http-zig | 7,577 | 41.16 ms | 41.95 ms | 0.05% |

### Spike (50→500→1000 VUs, 120s)

Server resilience under sudden traffic bursts.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **swerver** | 147,136 | 2.72 ms | 4.43 ms | 0% |
| actix | 137,189 | 2.85 ms | 4.59 ms | 0% |
| http-zig | 118,227 | 1.00 ms | 1.93 ms | 0.03% |
| nginx | 114,119 | 3.60 ms | 5.87 ms | 0% |
| apisix | 95,129 | 4.48 ms | 20.76 ms | 0% |

### Payload Size Scaling (5 sizes, 20 VUs each, 30s)

Performance across payload sizes from ~0B to 256KB.

| Server | Total RPS | Tiny (~0B) | Small (~15B) | Medium (8KB) | Large (64KB) | XLarge (256KB) |
|--------|-----------|------------|--------------|---------------|---------------|----------------|
| http-zig | 104,417 | 29,269 | 23,745 | 25,091 | 26,384 | 3 |
| actix | 80,062 | 18,274 | 18,721 | 17,536 | 14,182 | 11,358 |
| **swerver** | 63,616 | 14,872 | 14,748 | 13,600 | 10,453 | 9,947 |
| nginx | 42,932 | 9,772 | 9,724 | 9,106 | 7,615 | 6,785 |
| apisix | 35,740 | 8,588 | 8,605 | 7,800 | 5,717 | 5,032 |

### Keepalive Efficiency (50 VUs per mode, 30s)

Throughput gain from HTTP connection reuse.

| Server | Keepalive RPS | No-Keepalive RPS | Efficiency Gain | p99 Latency |
|--------|--------------|------------------|-----------------|-------------|
| **swerver** | 81,597 | 47,988 | +70% | 2.53 ms |
| http-zig | 87,320 | 30,292 | +188% | 2.82 ms |
| actix | 79,010 | 33,907 | +133% | 2.86 ms |
| nginx | 62,411 | 23,822 | +162% | 4.33 ms |
| apisix | 53,330 | 21,800 | +145% | 23.99 ms |

### Rapid-Fire (200 VUs, zero think time, 30s)

Maximum capacity ceiling on minimal endpoint.

| Server | Requests/sec | p95 Latency | p99 Latency | p99.9 Latency | Timeouts |
|--------|-------------|-------------|-------------|---------------|----------|
| **swerver** | 143,437 | 1.08 ms | 2.05 ms | 4.12 ms | 0% |
| actix | 128,155 | 1.25 ms | 2.26 ms | 4.23 ms | 0% |
| nginx | 125,346 | 1.19 ms | 2.04 ms | 3.84 ms | 0% |
| http-zig | 112,954 | 1.13 ms | 2.01 ms | 3.68 ms | 0% |
| apisix | 94,279 | 1.47 ms | 12.07 ms | 28.09 ms | 0% |

### Error Handling (100 VUs, 30s)

Error path performance (404s, wrong method, oversized headers, bad bodies).

| Server | Requests/sec | p95 Latency | p99 Latency | Correct Status |
|--------|-------------|-------------|-------------|----------------|
| actix | 141,755 | 1.49 ms | 2.65 ms | 100% |
| **swerver** | 114,455 | 1.09 ms | 2.02 ms | 100% |
| nginx | 80,053 | 1.89 ms | 34.97 ms | 100% |
| apisix | 71,470 | 2.14 ms | 35.48 ms | 100% |
| http-zig | 2,427 | 42.45 ms | 55.90 ms | 80% |

### TLS + HTTP/2 (100 VUs, 30s)

HTTPS and HTTP/2-over-TLS workloads. Tests swerver's TLS stack against nginx, actix (rustls), and APISIX. See `scenarios/tls-http2/`.

**TLS throughput** (GET /health with h2 over TLS):

| Server | Requests/sec | p95 Latency | Errors |
|--------|-------------|-------------|--------|
| actix | 171,726 | 1.29 ms | 0% |
| **swerver** | 161,781 | 0.86 ms | 0% |
| nginx | 107,741 | 1.72 ms | 0% |
| apisix | 71,851 | 1.93 ms | 0% |

**HTTP/2 throughput** (GET /echo with h2 over TLS):

| Server | Requests/sec | p95 Latency | Errors |
|--------|-------------|-------------|--------|
| actix | 129,428 | 1.46 ms | 0% |
| **swerver** | 111,698 | 1.08 ms | 0% |
| nginx | 95,878 | 1.78 ms | 0% |
| apisix | 68,731 | 1.86 ms | 0% |

**TLS handshake** (new TCP+TLS connection per request):

| Server | Req/sec | p95 Latency | Errors |
|--------|---------|-------------|--------|
| actix | 2,765 | 45.45 ms | 0% |
| **swerver** | 1,829 | 47.00 ms | 0% |
| nginx | 1,578 | 62.37 ms | 33.8% |
| apisix | 1,552 | 58.64 ms | 32.3% |

---

### Key Findings

**Native performance (wrk, single process):**
- **285K req/s** on plaintext — saturates single-core kqueue event loop
- **Sub-millisecond latency** across all endpoints at 100 connections
- **6.65 GB/s** throughput on large responses (1MB blob)
- Stable under high concurrency (500 connections, <2ms avg latency)

**Docker comparison (k6, containerized) — swerver wins 6/10 plain HTTP scenarios and 2/3 TLS scenarios:**

Plain HTTP (April 2026):
- **Throughput**: 147K req/s — 10% faster than actix (134K), 25% faster than nginx, 61% faster than APISIX
- **Connection handling**: 4.7x faster than nginx at new connections (90K vs 19K conn/s), 1.4x vs actix
- **Concurrent scaling**: Best throughput at 1000 VUs (157K req/s), beats actix by 5%
- **Spike resilience**: 147K req/s through 1000 VU spikes, 0% errors, 7% faster than actix
- **Rapid-fire**: 143K req/s ceiling — 12% faster than actix, 14% faster than nginx
- **Keepalive p99**: Best latency (2.53 ms) with 0% errors
- **Mixed workload**: 36.9K req/s — within 0.1% of nginx and actix (effective 3-way tie)
- **Error handling**: 114K req/s on error paths with 100% correct status codes, best p99 latency (2.02 ms)
- **Latency**: Tied with nginx/actix on /echo (3.29ms p99 vs 3.19ms)
- **Payload scaling**: 10.4K req/s at 64KB, 9.9K at 256KB — consistent across sizes (http-zig and actix faster on small bodies)

TLS + HTTP/2 (April 2026):
- **TLS throughput**: 162K req/s — 50% faster than nginx (108K), 125% faster than APISIX (72K), 6% behind actix (172K)
- **H2 throughput**: 112K req/s — 16% faster than nginx (96K), 62% faster than APISIX (69K), 14% behind actix (129K)
- **TLS handshake**: 1.8K req/s with 0% errors — nginx and APISIX both hit 30%+ error rates under the same load

**vs APISIX (the leading API gateway, nginx + LuaJIT):**
- Plain HTTP: 1.6x faster throughput, 3.9x faster connection setup, 1.5x faster concurrent scaling
- TLS: 2.25x faster throughput, 1.6x faster h2 throughput
- APISIX throws 32% TLS handshake errors vs swerver's 0%

**vs other Zig (http-zig):**
- 1.4x faster throughput, 3.1x faster connection setup, 4.9x faster mixed workload
- http-zig wins on payload (thread-per-connection avoids event loop overhead for large bodies)
- http-zig hits protocol errors on error-handling (43ms p95, 80% correct status)

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
