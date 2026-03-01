import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const BASE = `http://${__ENV.TARGET_HOST || 'swerver'}:${__ENV.TARGET_PORT || '8080'}`;
const vus = parseInt(__ENV.K6_VUS) || 100;
const duration = __ENV.K6_DURATION || '30s';
const errorRate = new Rate('errors');

const files = ['/static/index.html', '/static/styles.css', '/static/app.js'];

export const options = {
  vus: vus,
  duration: duration,
  thresholds: {
    errors: ['rate<0.01'],
    http_req_duration: ['p(95)<20'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(75)', 'p(90)', 'p(95)', 'p(99)'],
};

export default function () {
  const file = files[Math.floor(Math.random() * files.length)];
  const res = http.get(`${BASE}${file}`);
  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
    'body not empty': (r) => r.body && r.body.length > 0,
  });
  errorRate.add(!ok);
}

export function handleSummary(data) {
  const summary = {
    scenario: 'static-api-static',
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
    '/results/static-api-static.json': JSON.stringify(summary, null, 2),
  };
}
