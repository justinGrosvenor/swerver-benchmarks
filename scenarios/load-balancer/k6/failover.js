import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const BASE = `http://${__ENV.TARGET_HOST || 'swerver'}:${__ENV.TARGET_PORT || '8080'}`;
const errorRate = new Rate('errors');

const app1Count = new Counter('app1_requests');
const app2Count = new Counter('app2_requests');
const app3Count = new Counter('app3_requests');
const failedCount = new Counter('failed_requests');

export const options = {
  // 3 phases: before pause (12s), during pause (20s), after unpause (12s)
  stages: [
    { duration: '12s', target: 50 },
    { duration: '20s', target: 50 },
    { duration: '12s', target: 50 },
  ],
  thresholds: {
    errors: ['rate<0.10'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(95)', 'p(99)'],
};

export default function () {
  const res = http.get(`${BASE}/`);
  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
  });

  if (res.status === 200) {
    try {
      const instance = res.json().instance;
      if (instance === 'app-1') app1Count.add(1);
      else if (instance === 'app-2') app2Count.add(1);
      else if (instance === 'app-3') app3Count.add(1);
    } catch (e) {
      // non-JSON response
    }
  } else {
    failedCount.add(1);
  }
  errorRate.add(!ok);
}

export function handleSummary(data) {
  const total = data.metrics.http_reqs.values.count;
  const a1 = data.metrics.app1_requests ? data.metrics.app1_requests.values.count : 0;
  const a2 = data.metrics.app2_requests ? data.metrics.app2_requests.values.count : 0;
  const a3 = data.metrics.app3_requests ? data.metrics.app3_requests.values.count : 0;
  const failed = data.metrics.failed_requests ? data.metrics.failed_requests.values.count : 0;

  const summary = {
    scenario: 'lb-failover',
    timestamp: new Date().toISOString(),
    config: { stages: options.stages },
    distribution: {
      'app-1': a1,
      'app-2': a2,
      'app-3': a3,
      failed: failed,
    },
    note: 'app-3 paused at ~12s, unpaused at ~32s',
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
  text += '\n\n  Failover Distribution:\n';
  text += `    app-1: ${a1}\n`;
  text += `    app-2: ${a2}\n`;
  text += `    app-3: ${a3} (paused 12s-32s)\n`;
  text += `    failed: ${failed}\n`;

  return {
    stdout: text,
    '/results/lb-failover.json': JSON.stringify(summary, null, 2),
  };
}
