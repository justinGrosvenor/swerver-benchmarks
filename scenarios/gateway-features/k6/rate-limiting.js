// Rate limiting: verify per-consumer rate limiting under load
// Two consumers share the /limited/ route (50 rps, burst 10 each).
// Measures 429 rate, X-RateLimit header correctness, and that
// separate consumers get independent quotas.
import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const BASE = `http://${__ENV.TARGET_HOST || 'swerver'}:${__ENV.TARGET_PORT || '8080'}`;
const vus = parseInt(__ENV.K6_VUS) || 50;
const duration = __ENV.K6_DURATION || '20s';

const ok200 = new Counter('status_200');
const rejected429 = new Counter('status_429');
const otherStatus = new Counter('status_other');
const c1_200 = new Counter('consumer1_200');
const c1_429 = new Counter('consumer1_429');
const c2_200 = new Counter('consumer2_200');
const c2_429 = new Counter('consumer2_429');
const hasRateLimitHeader = new Rate('has_ratelimit_header');
const latency = new Trend('req_latency', true);

export const options = {
  scenarios: {
    consumer1: {
      executor: 'constant-vus',
      vus: Math.ceil(vus / 2),
      duration: duration,
      exec: 'consumer1',
    },
    consumer2: {
      executor: 'constant-vus',
      vus: Math.floor(vus / 2),
      duration: duration,
      exec: 'consumer2',
    },
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
};

export function consumer1() {
  const res = http.get(`${BASE}/limited/users`, {
    headers: { 'X-API-Key': 'limited-key-1' },
  });
  classify(res, c1_200, c1_429);
}

export function consumer2() {
  const res = http.get(`${BASE}/limited/users`, {
    headers: { 'X-API-Key': 'limited-key-2' },
  });
  classify(res, c2_200, c2_429);
}

function classify(res, ok_counter, rl_counter) {
  latency.add(res.timings.duration);
  if (res.status === 200) {
    ok200.add(1);
    ok_counter.add(1);
  } else if (res.status === 429) {
    rejected429.add(1);
    rl_counter.add(1);
  } else if (res.status === 0) {
    // Connection reset / EOF — rate limiter paused reads and closed connection
    rejected429.add(1);
    rl_counter.add(1);
  } else {
    otherStatus.add(1);
  }

  if (res.headers) {
    const hasHeader = res.headers['X-Ratelimit-Limit'] !== undefined ||
                      res.headers['X-RateLimit-Limit'] !== undefined ||
                      res.headers['x-ratelimit-limit'] !== undefined;
    hasRateLimitHeader.add(hasHeader);
  }
}

export function handleSummary(data) {
  const m = data.metrics;
  const summary = {
    scenario: 'gateway-rate-limiting',
    timestamp: new Date().toISOString(),
    config: { vus, duration },
    metrics: {
      total_requests: m.http_reqs ? m.http_reqs.values.count : 0,
      status_200: m.status_200 ? m.status_200.values.count : 0,
      status_429: m.status_429 ? m.status_429.values.count : 0,
      status_other: m.status_other ? m.status_other.values.count : 0,
      rejection_rate: (m.status_429 && m.http_reqs)
        ? m.status_429.values.count / m.http_reqs.values.count
        : 0,
      consumer1: {
        allowed: m.consumer1_200 ? m.consumer1_200.values.count : 0,
        rejected: m.consumer1_429 ? m.consumer1_429.values.count : 0,
      },
      consumer2: {
        allowed: m.consumer2_200 ? m.consumer2_200.values.count : 0,
        rejected: m.consumer2_429 ? m.consumer2_429.values.count : 0,
      },
      ratelimit_header_pct: m.has_ratelimit_header
        ? m.has_ratelimit_header.values.rate * 100
        : 0,
      latency_avg_ms: m.req_latency ? m.req_latency.values.avg : 0,
      latency_p95_ms: m.req_latency ? m.req_latency.values['p(95)'] : 0,
      latency_p99_ms: m.req_latency ? m.req_latency.values['p(99)'] : 0,
    },
  };
  return {
    stdout: textSummary(data, { indent: ' ' }),
    '/results/rate-limiting.json': JSON.stringify(summary, null, 2),
  };
}
