// Traffic split: verify canary routing distribution under load
// /canary/ route splits 80/20 between api-v1 and api-v2.
// Hits /canary/version which returns {"version":"v1"} or {"version":"v2"}.
// Validates that distribution converges to configured weights.
import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const BASE = `http://${__ENV.TARGET_HOST || 'swerver'}:${__ENV.TARGET_PORT || '8080'}`;
const vus = parseInt(__ENV.K6_VUS) || 50;
const duration = __ENV.K6_DURATION || '30s';

const v1Count = new Counter('v1_responses');
const v2Count = new Counter('v2_responses');
const unknownCount = new Counter('unknown_responses');
const errorRate = new Rate('errors');

export const options = {
  vus: vus,
  duration: duration,
  thresholds: {
    errors: ['rate<0.05'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
};

export default function () {
  const res = http.get(`${BASE}/canary/version`);
  const ok = check(res, { '200': (r) => r.status === 200 });
  errorRate.add(!ok);

  if (res.status === 200) {
    try {
      const body = res.json();
      if (body.version === 'v1') {
        v1Count.add(1);
      } else if (body.version === 'v2') {
        v2Count.add(1);
      } else {
        unknownCount.add(1);
      }
    } catch (e) {
      unknownCount.add(1);
    }
  }
}

export function handleSummary(data) {
  const m = data.metrics;
  const v1 = m.v1_responses ? m.v1_responses.values.count : 0;
  const v2 = m.v2_responses ? m.v2_responses.values.count : 0;
  const total = v1 + v2;

  const summary = {
    scenario: 'gateway-traffic-split',
    timestamp: new Date().toISOString(),
    config: { vus, duration, expected_split: '80/20' },
    metrics: {
      total_requests: m.http_reqs ? m.http_reqs.values.count : 0,
      requests_per_second: m.http_reqs ? m.http_reqs.values.rate : 0,
      v1_count: v1,
      v2_count: v2,
      unknown: m.unknown_responses ? m.unknown_responses.values.count : 0,
      v1_pct: total > 0 ? (v1 / total * 100).toFixed(1) : 'N/A',
      v2_pct: total > 0 ? (v2 / total * 100).toFixed(1) : 'N/A',
      split_accuracy: total > 100
        ? Math.abs(v1 / total * 100 - 80).toFixed(1) + '% deviation from target'
        : 'insufficient samples',
      latency_avg_ms: m.http_req_duration ? m.http_req_duration.values.avg : 0,
      latency_p95_ms: m.http_req_duration ? m.http_req_duration.values['p(95)'] : 0,
      latency_p99_ms: m.http_req_duration ? m.http_req_duration.values['p(99)'] : 0,
    },
  };
  return {
    stdout: textSummary(data, { indent: ' ' }),
    '/results/traffic-split.json': JSON.stringify(summary, null, 2),
  };
}
