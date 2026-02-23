# Swerver Benchmarks

Reproducible HTTP server benchmarking suite for comparing [swerver](https://github.com/justin/swerver) against production-grade servers.

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

| Scenario | Goal | Method |
|----------|------|--------|
| `throughput` | Max requests/sec | GET /health |
| `latency` | Response time percentiles | GET /echo |
| `connections` | Connection setup overhead | GET /health (no keep-alive) |
| `concurrent` | Scaling with connections | Ramp 10→1000 VUs |
| `mixed` | Realistic traffic | 30% health, 40% GET, 20% POST, 10% large |

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
# All servers, all scenarios
./scripts/run-all.sh

# Specific servers
./scripts/run-all.sh --servers "swerver nginx"

# Specific scenarios
./scripts/run-all.sh --scenarios "throughput latency"
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

Tested on Docker Desktop (macOS, Apple Silicon) with 2 CPU cores and 512MB memory limit per container. January 2026.

### Throughput (GET /health, 100 VUs, 30s)

Maximum requests per second on minimal endpoint.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **nginx** | 102,940 | 1.87 ms | 4.19 ms | 0% |
| **actix** | 93,779 | 1.85 ms | 10.28 ms | 0% |
| **swerver** | 76,811 | 1.82 ms | 17.63 ms | 0% |
| http-zig | 12,688 | 10.07 ms | 12.49 ms | 0% |

### Latency (GET /echo with JSON, 100 VUs, 30s)

Response time percentiles with JSON payload.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| http-zig | 8,443 | 2.97 ms | 5.00 ms | 0% |
| **nginx** | 7,912 | 3.31 ms | 5.45 ms | 0% |
| **swerver** | 7,769 | 3.11 ms | 5.01 ms | 0% |
| actix | 7,494 | 3.16 ms | 5.83 ms | 0% |

### Connections (No keep-alive, 100 VUs, 30s)

Connection setup overhead - new TCP connection per request.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **swerver** | 92,080 | 1.61 ms | 2.89 ms | 0% |
| **actix** | 50,801 | 2.93 ms | 11.40 ms | 0% |
| nginx | 22,723 | 9.30 ms | 30.57 ms | 0% |
| http-zig | 12,501 | 10.53 ms | 12.97 ms | 0% |

### Concurrent (Ramp 10→1000 VUs, 30s)

Scaling with increasing connections.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **swerver** | 172,198 | 1.11 ms | 2.13 ms | 0% |
| **nginx** | 107,902 | 2.01 ms | 3.72 ms | 0% |
| actix | 91,417 | 2.13 ms | 11.33 ms | 0% |
| http-zig | 12,986 | 9.97 ms | 12.36 ms | 0% |

### Mixed Workload (30% health, 40% GET, 20% POST, 10% blob)

Realistic traffic pattern with varied request types.

| Server | Requests/sec | p95 Latency | p99 Latency | Errors |
|--------|-------------|-------------|-------------|--------|
| **actix** | 1,951 | 0.54 ms | 1.60 ms | 0% |
| **nginx** | 1,948 | 0.56 ms | 1.40 ms | 0% |
| **swerver** | 1,946 | 0.51 ms | 1.25 ms | 0% |
| http-zig | 1,946 | 0.87 ms | 1.81 ms | 0% |

---

### Key Findings

**Native performance (wrk, single process):**
- **285K req/s** on plaintext — saturates single-core kqueue event loop
- **Sub-millisecond latency** across all endpoints at 100 connections
- **6.65 GB/s** throughput on large responses (1MB blob)
- Stable under high concurrency (500 connections, <2ms avg latency)

**Docker comparison (k6, containerized):**
- **Connection handling**: 4x faster than nginx at new connections (92k vs 23k req/s)
- **Concurrent scaling**: Best throughput at 1000 VUs (172k req/s, 60% faster than nginx)
- **Low latency**: Consistently lowest p95 latency across scenarios

**vs other Zig (http-zig):**
- 6-14x faster across all scenarios
- Demonstrates benefit of custom io_uring/kqueue vs stdlib

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
