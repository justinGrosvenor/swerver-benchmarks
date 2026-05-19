// Caching: measure response cache effectiveness
// /cached/expensive is cached with 10s TTL (upstream has 50ms delay).
// /noauth/expensive goes direct to upstream every time.
// Measures: throughput multiplier, latency improvement, cache hit consistency.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const BASE = `http://${__ENV.TARGET_HOST || 'swerver'}:${__ENV.TARGET_PORT || '8080'}`;
const vus = parseInt(__ENV.K6_VUS) || 20;
const duration = __ENV.K6_DURATION || '30s';

const directLatency = new Trend('direct_latency', true);
const cachedLatency = new Trend('cached_latency', true);
const directCount = new Counter('direct_reqs');
const cachedCount = new Counter('cached_reqs');
const errorRate = new Rate('errors');

export const options = {
  scenarios: {
    warmup: {
      executor: 'shared-iterations',
      vus: 1,
      iterations: 5,
      exec: 'warmCache',
      maxDuration: '10s',
    },
    direct: {
      executor: 'constant-vus',
      vus: vus,
      duration: duration,
      exec: 'direct',
      startTime: '5s',
    },
    cached: {
      executor: 'constant-vus',
      vus: vus,
      duration: duration,
      exec: 'cached',
      startTime: '5s',
    },
  },
  thresholds: {
    errors: ['rate<0.05'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
};

export function warmCache() {
  // Prime the cache with a few requests
  http.get(`${BASE}/cached/catalog`);
  http.get(`${BASE}/cached/users`);
  http.get(`${BASE}/cached/expensive`);
  sleep(0.5);
}

export function direct() {
  const res = http.get(`${BASE}/noauth/expensive`);
  const ok = check(res, { 'direct 200': (r) => r.status === 200 });
  directLatency.add(res.timings.duration);
  directCount.add(1);
  errorRate.add(!ok);
}

export function cached() {
  const res = http.get(`${BASE}/cached/expensive`);
  const ok = check(res, { 'cached 200': (r) => r.status === 200 });
  cachedLatency.add(res.timings.duration);
  cachedCount.add(1);
  errorRate.add(!ok);
}

export function handleSummary(data) {
  const m = data.metrics;
  const directReqs = m.direct_reqs ? m.direct_reqs.values.count : 0;
  const cachedReqs = m.cached_reqs ? m.cached_reqs.values.count : 0;
  const directAvg = m.direct_latency ? m.direct_latency.values.avg : 0;
  const cachedAvg = m.cached_latency ? m.cached_latency.values.avg : 0;

  const summary = {
    scenario: 'gateway-caching',
    timestamp: new Date().toISOString(),
    config: { vus_per_scenario: vus, duration },
    metrics: {
      direct: {
        requests: directReqs,
        latency_avg_ms: directAvg,
        latency_p95_ms: m.direct_latency ? m.direct_latency.values['p(95)'] : 0,
        latency_p99_ms: m.direct_latency ? m.direct_latency.values['p(99)'] : 0,
      },
      cached: {
        requests: cachedReqs,
        latency_avg_ms: cachedAvg,
        latency_p95_ms: m.cached_latency ? m.cached_latency.values['p(95)'] : 0,
        latency_p99_ms: m.cached_latency ? m.cached_latency.values['p(99)'] : 0,
      },
      throughput_multiplier: directReqs > 0
        ? (cachedReqs / directReqs).toFixed(2)
        : 'N/A',
      latency_improvement_pct: directAvg > 0
        ? ((1 - cachedAvg / directAvg) * 100).toFixed(1)
        : 'N/A',
    },
  };
  return {
    stdout: textSummary(data, { indent: ' ' }),
    '/results/caching.json': JSON.stringify(summary, null, 2),
  };
}
