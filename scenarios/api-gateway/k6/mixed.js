import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const BASE = `http://${__ENV.TARGET_HOST || 'swerver'}:${__ENV.TARGET_PORT || '8080'}`;
const vus = parseInt(__ENV.K6_VUS) || 100;
const duration = __ENV.K6_DURATION || '30s';
const errorRate = new Rate('errors');

export const options = {
  vus: vus,
  duration: duration,
  thresholds: {
    errors: ['rate<0.05'],
    http_req_duration: ['p(95)<100'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(75)', 'p(90)', 'p(95)', 'p(99)'],
};

export default function () {
  const roll = Math.random();
  let res;

  if (roll < 0.40) {
    // 40% — user list
    res = http.get(`${BASE}/api/users`);
  } else if (roll < 0.70) {
    // 30% — product list
    res = http.get(`${BASE}/api/products`);
  } else if (roll < 0.90) {
    // 20% — user by id
    const id = Math.ceil(Math.random() * 3);
    res = http.get(`${BASE}/api/users/${id}`);
  } else {
    // 10% — POST create user
    res = http.post(`${BASE}/api/users`, JSON.stringify({
      name: `k6-user-${Date.now()}`,
      email: `k6-${Date.now()}@test.com`,
    }), { headers: { 'Content-Type': 'application/json' } });
  }

  const ok = check(res, {
    'status is 2xx': (r) => r.status >= 200 && r.status < 300,
  });
  errorRate.add(!ok);
}

export function handleSummary(data) {
  const summary = {
    scenario: 'api-gateway-mixed',
    timestamp: new Date().toISOString(),
    config: { vus: vus, duration: duration },
    metrics: {
      requests_total: data.metrics.http_reqs.values.count,
      requests_per_second: data.metrics.http_reqs.values.rate,
      error_rate: data.metrics.http_req_failed ? data.metrics.http_req_failed.values.rate : 0,
      latency_avg_ms: data.metrics.http_req_duration.values.avg,
      latency_p95_ms: data.metrics.http_req_duration.values['p(95)'],
      latency_p99_ms: data.metrics.http_req_duration.values['p(99)'],
      latency_max_ms: data.metrics.http_req_duration.values.max,
    },
  };
  return {
    stdout: textSummary(data, { indent: ' ' }),
    '/results/api-gateway-mixed.json': JSON.stringify(summary, null, 2),
  };
}
