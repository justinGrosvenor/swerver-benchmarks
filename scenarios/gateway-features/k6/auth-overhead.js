// Auth overhead: compare no-auth vs API key vs JWT throughput
// Measures the cost of authentication per request under load.
import http from 'k6/http';
import { check } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const BASE = `http://${__ENV.TARGET_HOST || 'swerver'}:${__ENV.TARGET_PORT || '8080'}`;
const vus = parseInt(__ENV.K6_VUS) || 100;
const duration = __ENV.K6_DURATION || '30s';

// Per-auth-type metrics
const noauthLatency = new Trend('noauth_latency', true);
const apikeyLatency = new Trend('apikey_latency', true);
const jwtLatency = new Trend('jwt_latency', true);
const noauthCount = new Counter('noauth_reqs');
const apikeyCount = new Counter('apikey_reqs');
const jwtCount = new Counter('jwt_reqs');
const errorRate = new Rate('errors');

// Pre-computed JWT token (HS256, secret=bench-jwt-secret-key-for-testing-only)
// Payload: {"sub":"bench-user","iss":"bench","exp":4102444800}  (expires 2100)
const JWT_TOKEN = __ENV.JWT_TOKEN || buildJwt();

function buildJwt() {
  // Pre-computed HS256 JWT. Secret: bench-jwt-secret-key-for-testing-only
  // Payload: {"sub":"bench-user","iss":"bench","exp":4102444800}
  return 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJiZW5jaC11c2VyIiwiaXNzIjoiYmVuY2giLCJleHAiOjQxMDI0NDQ4MDB9.GTeLqNPzf2qg-s56vq-O2feZP735Cbujc_VL9DU--Sk';
}

export const options = {
  // Multi-scenario — do not set K6_VUS env var (it overrides scenarios).
  scenarios: {
    noauth: {
      executor: 'constant-vus',
      vus: vus,
      duration: duration,
      exec: 'noauth',
    },
    apikey: {
      executor: 'constant-vus',
      vus: vus,
      duration: duration,
      exec: 'apikey',
      startTime: '0s',
    },
    jwt: {
      executor: 'constant-vus',
      vus: vus,
      duration: duration,
      exec: 'jwtAuth',
      startTime: '0s',
    },
  },
  thresholds: {
    errors: ['rate<0.05'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(75)', 'p(90)', 'p(95)', 'p(99)'],
};

export function noauth() {
  const res = http.get(`${BASE}/noauth/users`);
  const ok = check(res, { 'noauth 200': (r) => r.status === 200 });
  noauthLatency.add(res.timings.duration);
  noauthCount.add(1);
  errorRate.add(!ok);
}

export function apikey() {
  const keys = ['bench-key-1', 'bench-key-2', 'bench-key-3'];
  const key = keys[Math.floor(Math.random() * keys.length)];
  const res = http.get(`${BASE}/authed/users`, {
    headers: { 'X-API-Key': key },
  });
  const ok = check(res, { 'apikey 200': (r) => r.status === 200 });
  apikeyLatency.add(res.timings.duration);
  apikeyCount.add(1);
  errorRate.add(!ok);
}

export function jwtAuth() {
  const res = http.get(`${BASE}/jwt/users`, {
    headers: { 'Authorization': `Bearer ${JWT_TOKEN}` },
  });
  // JWT may 401 if placeholder token — track separately
  const ok = check(res, { 'jwt 2xx': (r) => r.status >= 200 && r.status < 300 });
  jwtLatency.add(res.timings.duration);
  jwtCount.add(1);
  errorRate.add(!ok);
}

export function handleSummary(data) {
  const m = data.metrics;
  const summary = {
    scenario: 'gateway-auth-overhead',
    timestamp: new Date().toISOString(),
    config: { vus_per_scenario: vus, duration },
    metrics: {
      noauth: {
        requests: m.noauth_reqs ? m.noauth_reqs.values.count : 0,
        latency_avg_ms: m.noauth_latency ? m.noauth_latency.values.avg : 0,
        latency_p95_ms: m.noauth_latency ? m.noauth_latency.values['p(95)'] : 0,
        latency_p99_ms: m.noauth_latency ? m.noauth_latency.values['p(99)'] : 0,
      },
      apikey: {
        requests: m.apikey_reqs ? m.apikey_reqs.values.count : 0,
        latency_avg_ms: m.apikey_latency ? m.apikey_latency.values.avg : 0,
        latency_p95_ms: m.apikey_latency ? m.apikey_latency.values['p(95)'] : 0,
        latency_p99_ms: m.apikey_latency ? m.apikey_latency.values['p(99)'] : 0,
      },
      jwt: {
        requests: m.jwt_reqs ? m.jwt_reqs.values.count : 0,
        latency_avg_ms: m.jwt_latency ? m.jwt_latency.values.avg : 0,
        latency_p95_ms: m.jwt_latency ? m.jwt_latency.values['p(95)'] : 0,
        latency_p99_ms: m.jwt_latency ? m.jwt_latency.values['p(99)'] : 0,
      },
    },
  };
  return {
    stdout: textSummary(data, { indent: ' ' }),
    '/results/auth-overhead.json': JSON.stringify(summary, null, 2),
  };
}
