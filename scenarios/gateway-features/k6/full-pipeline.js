// Full pipeline: realistic mixed gateway workload
// Exercises all features simultaneously to measure aggregate behavior.
// Distribution: 30% cached reads, 25% authed reads, 20% validated writes,
// 15% rate-limited, 10% canary routed.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Counter } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const BASE = `http://${__ENV.TARGET_HOST || 'swerver'}:${__ENV.TARGET_PORT || '8080'}`;
const vus = parseInt(__ENV.K6_VUS) || 100;
const duration = __ENV.K6_DURATION || '60s';

const errorRate = new Rate('errors');
const cachedReqs = new Counter('cached_reqs');
const authedReqs = new Counter('authed_reqs');
const validatedReqs = new Counter('validated_reqs');
const limitedReqs = new Counter('limited_reqs');
const canaryReqs = new Counter('canary_reqs');
const rejected429 = new Counter('rejected_429');
const rejected400 = new Counter('rejected_400');

const KEYS = ['bench-key-1', 'bench-key-2', 'bench-key-3'];
const VALID_BODY = JSON.stringify({ name: 'User', email: 'user@test.com' });
const JSON_HEADERS = { headers: { 'Content-Type': 'application/json' } };

export const options = {
  vus: vus,
  duration: duration,
  thresholds: {
    'http_req_duration': ['p(95)<200'],
    errors: ['rate<0.10'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(75)', 'p(90)', 'p(95)', 'p(99)'],
};

export default function () {
  const roll = Math.random();
  let res;

  if (roll < 0.30) {
    // 30% — cached catalog read
    res = http.get(`${BASE}/cached/catalog`);
    cachedReqs.add(1);
    check(res, { 'cached 200': (r) => r.status === 200 });
  } else if (roll < 0.55) {
    // 25% — API key authed read
    const key = KEYS[Math.floor(Math.random() * KEYS.length)];
    res = http.get(`${BASE}/authed/users`, {
      headers: { 'X-API-Key': key },
    });
    authedReqs.add(1);
    check(res, { 'authed 200': (r) => r.status === 200 });
  } else if (roll < 0.75) {
    // 20% — validated POST
    res = http.post(`${BASE}/validated/validate`, VALID_BODY, JSON_HEADERS);
    validatedReqs.add(1);
    check(res, { 'validated 2xx': (r) => r.status >= 200 && r.status < 300 });
  } else if (roll < 0.90) {
    // 15% — rate-limited read
    const key = Math.random() < 0.5 ? 'limited-key-1' : 'limited-key-2';
    res = http.get(`${BASE}/limited/users`, {
      headers: { 'X-API-Key': key },
    });
    limitedReqs.add(1);
    if (res.status === 429) rejected429.add(1);
    check(res, { 'limited 200 or 429': (r) => r.status === 200 || r.status === 429 });
  } else {
    // 10% — canary routed
    res = http.get(`${BASE}/canary/version`);
    canaryReqs.add(1);
    check(res, { 'canary 200': (r) => r.status === 200 });
  }

  const ok = res.status >= 200 && res.status < 500;
  errorRate.add(!ok);
}

export function handleSummary(data) {
  const m = data.metrics;
  const summary = {
    scenario: 'gateway-full-pipeline',
    timestamp: new Date().toISOString(),
    config: { vus, duration },
    metrics: {
      total_requests: m.http_reqs ? m.http_reqs.values.count : 0,
      requests_per_second: m.http_reqs ? m.http_reqs.values.rate : 0,
      error_rate: m.errors ? m.errors.values.rate : 0,
      latency_avg_ms: m.http_req_duration ? m.http_req_duration.values.avg : 0,
      latency_p95_ms: m.http_req_duration ? m.http_req_duration.values['p(95)'] : 0,
      latency_p99_ms: m.http_req_duration ? m.http_req_duration.values['p(99)'] : 0,
      latency_max_ms: m.http_req_duration ? m.http_req_duration.values.max : 0,
      breakdown: {
        cached: m.cached_reqs ? m.cached_reqs.values.count : 0,
        authed: m.authed_reqs ? m.authed_reqs.values.count : 0,
        validated: m.validated_reqs ? m.validated_reqs.values.count : 0,
        limited: m.limited_reqs ? m.limited_reqs.values.count : 0,
        canary: m.canary_reqs ? m.canary_reqs.values.count : 0,
      },
      rate_limited_429s: m.rejected_429 ? m.rejected_429.values.count : 0,
    },
  };
  return {
    stdout: textSummary(data, { indent: ' ' }),
    '/results/full-pipeline.json': JSON.stringify(summary, null, 2),
  };
}
