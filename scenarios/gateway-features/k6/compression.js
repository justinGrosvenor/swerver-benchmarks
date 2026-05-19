// Compression: measure gzip throughput vs uncompressed for large JSON
// Hits /noauth/catalog (large 200-item JSON array).
// Compares: no Accept-Encoding vs gzip vs deflate.
// Key metrics: bandwidth savings, latency delta, throughput.
import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const BASE = `http://${__ENV.TARGET_HOST || 'swerver'}:${__ENV.TARGET_PORT || '8080'}`;
const vus = parseInt(__ENV.K6_VUS) || 50;
const duration = __ENV.K6_DURATION || '30s';

const plainLatency = new Trend('plain_latency', true);
const gzipLatency = new Trend('gzip_latency', true);
const plainBytes = new Counter('plain_bytes');
const gzipBytes = new Counter('gzip_bytes');
const plainCount = new Counter('plain_reqs');
const gzipCount = new Counter('gzip_reqs');
const gzipEncoded = new Counter('gzip_encoded');

export const options = {
  scenarios: {
    plain: {
      executor: 'constant-vus',
      vus: vus,
      duration: duration,
      exec: 'plain',
    },
    gzip: {
      executor: 'constant-vus',
      vus: vus,
      duration: duration,
      exec: 'gzip',
      startTime: '0s',
    },
  },
  thresholds: {
    'http_req_failed': ['rate<0.05'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
};

export function plain() {
  const res = http.get(`${BASE}/noauth/catalog`, {
    headers: { 'Accept': 'application/json' },
  });
  check(res, { 'plain 200': (r) => r.status === 200 });
  plainLatency.add(res.timings.duration);
  plainBytes.add(parseInt(res.headers['Content-Length'] || res.body.length));
  plainCount.add(1);
}

export function gzip() {
  const res = http.get(`${BASE}/noauth/catalog`, {
    headers: { 'Accept': 'application/json', 'Accept-Encoding': 'gzip' },
  });
  check(res, { 'gzip 200': (r) => r.status === 200 });
  gzipLatency.add(res.timings.duration);
  const ce = res.headers['Content-Encoding'] || res.headers['content-encoding'] || '';
  if (ce.includes('gzip')) {
    gzipEncoded.add(1);
  }
  gzipBytes.add(parseInt(res.headers['Content-Length'] || res.body.length));
  gzipCount.add(1);
}

export function handleSummary(data) {
  const m = data.metrics;
  const plainTotal = m.plain_bytes ? m.plain_bytes.values.count : 0;
  const gzipTotal = m.gzip_bytes ? m.gzip_bytes.values.count : 0;
  const plainReqs = m.plain_reqs ? m.plain_reqs.values.count : 1;
  const gzipReqs = m.gzip_reqs ? m.gzip_reqs.values.count : 1;

  const summary = {
    scenario: 'gateway-compression',
    timestamp: new Date().toISOString(),
    config: { vus_per_scenario: vus, duration },
    metrics: {
      plain: {
        requests: plainReqs,
        total_bytes: plainTotal,
        avg_bytes_per_response: Math.round(plainTotal / plainReqs),
        latency_avg_ms: m.plain_latency ? m.plain_latency.values.avg : 0,
        latency_p95_ms: m.plain_latency ? m.plain_latency.values['p(95)'] : 0,
        latency_p99_ms: m.plain_latency ? m.plain_latency.values['p(99)'] : 0,
      },
      gzip: {
        requests: gzipReqs,
        total_bytes: gzipTotal,
        avg_bytes_per_response: Math.round(gzipTotal / gzipReqs),
        encoded_responses: m.gzip_encoded ? m.gzip_encoded.values.count : 0,
        latency_avg_ms: m.gzip_latency ? m.gzip_latency.values.avg : 0,
        latency_p95_ms: m.gzip_latency ? m.gzip_latency.values['p(95)'] : 0,
        latency_p99_ms: m.gzip_latency ? m.gzip_latency.values['p(99)'] : 0,
      },
      bandwidth_savings_pct: plainTotal > 0 && gzipTotal > 0
        ? ((1 - (gzipTotal / gzipReqs) / (plainTotal / plainReqs)) * 100).toFixed(1)
        : 'N/A',
    },
  };
  return {
    stdout: textSummary(data, { indent: ' ' }),
    '/results/compression.json': JSON.stringify(summary, null, 2),
  };
}
