// Body validation: measure JSON Schema validation overhead
// Compares POST to /validated/ (schema-checked) vs /noauth/ (unchecked).
// Also tests rejection of invalid bodies.
import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const BASE = `http://${__ENV.TARGET_HOST || 'swerver'}:${__ENV.TARGET_PORT || '8080'}`;
const vus = parseInt(__ENV.K6_VUS) || 50;
const duration = __ENV.K6_DURATION || '20s';

const uncheckedLatency = new Trend('unchecked_latency', true);
const validatedLatency = new Trend('validated_latency', true);
const rejectedLatency = new Trend('rejected_latency', true);
const uncheckedCount = new Counter('unchecked_reqs');
const validatedCount = new Counter('validated_reqs');
const rejectedCount = new Counter('rejected_reqs');
const errorRate = new Rate('errors');

const VALID_BODY = JSON.stringify({
  name: 'Test User',
  email: 'test@example.com',
});

const INVALID_BODY = JSON.stringify({
  name: '',
  extra_field: 'not in schema',
});

const JSON_HEADERS = { headers: { 'Content-Type': 'application/json' } };

export const options = {
  scenarios: {
    unchecked: {
      executor: 'constant-vus',
      vus: vus,
      duration: duration,
      exec: 'unchecked',
    },
    validated: {
      executor: 'constant-vus',
      vus: vus,
      duration: duration,
      exec: 'validated',
      startTime: '0s',
    },
    rejected: {
      executor: 'constant-vus',
      vus: Math.ceil(vus / 4),
      duration: duration,
      exec: 'rejected',
      startTime: '0s',
    },
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
};

export function unchecked() {
  const res = http.post(`${BASE}/noauth/validate`, VALID_BODY, JSON_HEADERS);
  const ok = check(res, { 'unchecked 2xx': (r) => r.status >= 200 && r.status < 300 });
  uncheckedLatency.add(res.timings.duration);
  uncheckedCount.add(1);
  errorRate.add(!ok);
}

export function validated() {
  const res = http.post(`${BASE}/validated/validate`, VALID_BODY, JSON_HEADERS);
  const ok = check(res, { 'validated 2xx': (r) => r.status >= 200 && r.status < 300 });
  validatedLatency.add(res.timings.duration);
  validatedCount.add(1);
  errorRate.add(!ok);
}

export function rejected() {
  const res = http.post(`${BASE}/validated/validate`, INVALID_BODY, JSON_HEADERS);
  const ok = check(res, { 'rejected 400': (r) => r.status === 400 });
  rejectedLatency.add(res.timings.duration);
  rejectedCount.add(1);
  errorRate.add(!ok);
}

export function handleSummary(data) {
  const m = data.metrics;
  const summary = {
    scenario: 'gateway-body-validation',
    timestamp: new Date().toISOString(),
    config: { vus, duration },
    metrics: {
      unchecked: {
        requests: m.unchecked_reqs ? m.unchecked_reqs.values.count : 0,
        latency_avg_ms: m.unchecked_latency ? m.unchecked_latency.values.avg : 0,
        latency_p95_ms: m.unchecked_latency ? m.unchecked_latency.values['p(95)'] : 0,
        latency_p99_ms: m.unchecked_latency ? m.unchecked_latency.values['p(99)'] : 0,
      },
      validated: {
        requests: m.validated_reqs ? m.validated_reqs.values.count : 0,
        latency_avg_ms: m.validated_latency ? m.validated_latency.values.avg : 0,
        latency_p95_ms: m.validated_latency ? m.validated_latency.values['p(95)'] : 0,
        latency_p99_ms: m.validated_latency ? m.validated_latency.values['p(99)'] : 0,
      },
      rejected: {
        requests: m.rejected_reqs ? m.rejected_reqs.values.count : 0,
        latency_avg_ms: m.rejected_latency ? m.rejected_latency.values.avg : 0,
        latency_p95_ms: m.rejected_latency ? m.rejected_latency.values['p(95)'] : 0,
        latency_p99_ms: m.rejected_latency ? m.rejected_latency.values['p(99)'] : 0,
      },
      validation_overhead_pct:
        (m.unchecked_latency && m.validated_latency && m.unchecked_latency.values.avg > 0)
          ? ((m.validated_latency.values.avg / m.unchecked_latency.values.avg - 1) * 100).toFixed(1)
          : 'N/A',
    },
  };
  return {
    stdout: textSummary(data, { indent: ' ' }),
    '/results/body-validation.json': JSON.stringify(summary, null, 2),
  };
}
