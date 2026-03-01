import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const BASE = `http://${__ENV.TARGET_HOST || 'swerver'}:${__ENV.TARGET_PORT || '8080'}`;
const vus = parseInt(__ENV.K6_VUS) || 50;
const duration = __ENV.K6_DURATION || '30s';
const errorRate = new Rate('errors');

const app1Count = new Counter('app1_requests');
const app2Count = new Counter('app2_requests');
const app3Count = new Counter('app3_requests');

export const options = {
  vus: vus,
  duration: duration,
  thresholds: {
    errors: ['rate<0.01'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(95)', 'p(99)'],
};

export default function () {
  const res = http.get(`${BASE}/`);
  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
    'has instance field': (r) => r.json().instance !== undefined,
  });
  errorRate.add(!ok);

  if (res.status === 200) {
    const instance = res.json().instance;
    if (instance === 'app-1') app1Count.add(1);
    else if (instance === 'app-2') app2Count.add(1);
    else if (instance === 'app-3') app3Count.add(1);
  }
}

export function handleSummary(data) {
  const total = data.metrics.http_reqs.values.count;
  const a1 = data.metrics.app1_requests ? data.metrics.app1_requests.values.count : 0;
  const a2 = data.metrics.app2_requests ? data.metrics.app2_requests.values.count : 0;
  const a3 = data.metrics.app3_requests ? data.metrics.app3_requests.values.count : 0;
  const tracked = a1 + a2 + a3;

  const summary = {
    scenario: 'lb-distribution',
    timestamp: new Date().toISOString(),
    config: { vus: vus, duration: duration },
    distribution: {
      'app-1': { count: a1, pct: tracked > 0 ? ((a1 / tracked) * 100).toFixed(1) : '0' },
      'app-2': { count: a2, pct: tracked > 0 ? ((a2 / tracked) * 100).toFixed(1) : '0' },
      'app-3': { count: a3, pct: tracked > 0 ? ((a3 / tracked) * 100).toFixed(1) : '0' },
      expected: '50:33:17',
    },
    metrics: {
      requests_total: total,
      requests_per_second: data.metrics.http_reqs.values.rate,
      error_rate: data.metrics.http_req_failed ? data.metrics.http_req_failed.values.rate : 0,
      latency_avg_ms: data.metrics.http_req_duration.values.avg,
      latency_p95_ms: data.metrics.http_req_duration.values['p(95)'],
      latency_p99_ms: data.metrics.http_req_duration.values['p(99)'],
    },
  };

  let text = textSummary(data, { indent: ' ' });
  text += '\n\n  Distribution:\n';
  text += `    app-1: ${a1} (${summary.distribution['app-1'].pct}%) — expected ~50%\n`;
  text += `    app-2: ${a2} (${summary.distribution['app-2'].pct}%) — expected ~33%\n`;
  text += `    app-3: ${a3} (${summary.distribution['app-3'].pct}%) — expected ~17%\n`;

  return {
    stdout: text,
    '/results/lb-distribution.json': JSON.stringify(summary, null, 2),
  };
}
