import http from 'k6/http';
import { check, group } from 'k6';
import { Rate } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const BASE = `http://${__ENV.TARGET_HOST || 'swerver'}:${__ENV.TARGET_PORT || '8080'}`;
const errorRate = new Rate('errors');

export const options = {
  vus: 10,
  iterations: 50,
  thresholds: {
    errors: ['rate<0.01'],
    http_req_failed: ['rate<0.01'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(95)', 'p(99)'],
};

export default function () {
  group('users routes', () => {
    let res = http.get(`${BASE}/api/users`);
    let ok = check(res, {
      'GET /api/users is 200': (r) => r.status === 200,
      'returns array': (r) => Array.isArray(r.json()),
      'has users': (r) => r.json().length >= 3,
    });
    errorRate.add(!ok);

    res = http.get(`${BASE}/api/users/1`);
    ok = check(res, {
      'GET /api/users/1 is 200': (r) => r.status === 200,
      'returns user with id 1': (r) => r.json().id === 1,
    });
    errorRate.add(!ok);
  });

  group('products routes', () => {
    let res = http.get(`${BASE}/api/products`);
    let ok = check(res, {
      'GET /api/products is 200': (r) => r.status === 200,
      'returns array': (r) => Array.isArray(r.json()),
      'has products': (r) => r.json().length >= 3,
    });
    errorRate.add(!ok);

    res = http.get(`${BASE}/api/products/2`);
    ok = check(res, {
      'GET /api/products/2 is 200': (r) => r.status === 200,
      'returns product with id 2': (r) => r.json().id === 2,
    });
    errorRate.add(!ok);
  });

  group('unknown routes', () => {
    const res = http.get(`${BASE}/api/unknown`);
    const ok = check(res, {
      'unknown route is 404': (r) => r.status === 404,
    });
    errorRate.add(!ok);
  });
}

export function handleSummary(data) {
  const summary = {
    scenario: 'api-gateway-routing',
    timestamp: new Date().toISOString(),
    config: { vus: options.vus, iterations: options.iterations },
    metrics: {
      requests_total: data.metrics.http_reqs.values.count,
      error_rate: data.metrics.http_req_failed ? data.metrics.http_req_failed.values.rate : 0,
      latency_avg_ms: data.metrics.http_req_duration.values.avg,
      latency_p95_ms: data.metrics.http_req_duration.values['p(95)'],
      latency_p99_ms: data.metrics.http_req_duration.values['p(99)'],
    },
  };
  return {
    stdout: textSummary(data, { indent: ' ' }),
    '/results/api-gateway-routing.json': JSON.stringify(summary, null, 2),
  };
}
