// Payload size scaling benchmark
// Goal: Test how server performance varies with different payload sizes

import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { config, baseUrl, defaultParams, randomJsonBody } from '/lib/helpers.js';
import { textSummary } from '/lib/summary.js';

// Per-size custom metrics
const tinyLatency = new Trend('tiny_latency', true);
const smallLatency = new Trend('small_latency', true);
const mediumLatency = new Trend('medium_latency', true);
const largeLatency = new Trend('large_latency', true);
const xlargeLatency = new Trend('xlarge_latency', true);

const tinyRps = new Counter('tiny_requests');
const smallRps = new Counter('small_requests');
const mediumRps = new Counter('medium_requests');
const largeRps = new Counter('large_requests');
const xlargeRps = new Counter('xlarge_requests');

// Pre-generate large bodies at init time
const largeBody = randomJsonBody(64 * 1024);    // 64KB
const xlargeBody = randomJsonBody(256 * 1024);  // 256KB

const postParams = {
    ...defaultParams,
    headers: {
        ...defaultParams.headers,
        'Content-Type': 'application/json',
    },
};

export const options = {
    scenarios: {
        tiny: {
            executor: 'constant-vus',
            vus: 20,
            duration: '30s',
            exec: 'tiny',
        },
        small: {
            executor: 'constant-vus',
            vus: 20,
            duration: '30s',
            exec: 'small',
        },
        medium: {
            executor: 'constant-vus',
            vus: 20,
            duration: '30s',
            exec: 'medium',
        },
        large: {
            executor: 'constant-vus',
            vus: 20,
            duration: '30s',
            exec: 'large',
        },
        xlarge: {
            executor: 'constant-vus',
            vus: 20,
            duration: '30s',
            exec: 'xlarge',
        },
    },
    thresholds: {
        http_req_duration: ['p(95)<500'],
        http_req_failed: ['rate<0.05'],
    },
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

// Tiny: GET /health (~0B response body)
export function tiny() {
    const res = http.get(`${baseUrl}/health`, defaultParams);
    check(res, { 'status is 200': (r) => r.status === 200 });
    tinyLatency.add(res.timings.duration);
    tinyRps.add(1);
}

// Small: GET /echo (~15B JSON response)
export function small() {
    const res = http.get(`${baseUrl}/echo`, defaultParams);
    check(res, { 'status is 200': (r) => r.status === 200 });
    smallLatency.add(res.timings.duration);
    smallRps.add(1);
}

// Medium: GET /blob (8KB response)
export function medium() {
    const res = http.get(`${baseUrl}/blob`, {
        ...defaultParams,
        responseType: 'binary',
    });
    check(res, { 'status is 200': (r) => r.status === 200 });
    mediumLatency.add(res.timings.duration);
    mediumRps.add(1);
}

// Large: POST /echo with 64KB body
export function large() {
    const res = http.post(`${baseUrl}/echo`, largeBody, postParams);
    check(res, { 'status is 200': (r) => r.status === 200 });
    largeLatency.add(res.timings.duration);
    largeRps.add(1);
}

// XLarge: POST /echo with 256KB body
export function xlarge() {
    const res = http.post(`${baseUrl}/echo`, xlargeBody, postParams);
    check(res, { 'status is 200': (r) => r.status === 200 });
    xlargeLatency.add(res.timings.duration);
    xlargeRps.add(1);
}

export function handleSummary(data) {
    const duration = 30; // seconds
    const summary = {
        scenario: 'payload',
        timestamp: new Date().toISOString(),
        server: config.targetHost,
        config: {
            vus_per_size: 20,
            duration: '30s',
            sizes: ['tiny (~0B)', 'small (~15B)', 'medium (8KB)', 'large (64KB)', 'xlarge (256KB)'],
        },
        metrics: {
            requests_total: data.metrics.http_reqs.values.count,
            requests_per_second: data.metrics.http_reqs.values.rate,
            error_rate: data.metrics.http_req_failed.values.rate,
            latency_p95_ms: data.metrics.http_req_duration.values['p(95)'],
            latency_p99_ms: data.metrics.http_req_duration.values['p(99)'],
            // Per-size metrics
            tiny_rps: (data.metrics.tiny_requests?.values?.count || 0) / duration,
            tiny_latency_p95_ms: data.metrics.tiny_latency?.values?.['p(95)'] || null,
            small_rps: (data.metrics.small_requests?.values?.count || 0) / duration,
            small_latency_p95_ms: data.metrics.small_latency?.values?.['p(95)'] || null,
            medium_rps: (data.metrics.medium_requests?.values?.count || 0) / duration,
            medium_latency_p95_ms: data.metrics.medium_latency?.values?.['p(95)'] || null,
            large_rps: (data.metrics.large_requests?.values?.count || 0) / duration,
            large_latency_p95_ms: data.metrics.large_latency?.values?.['p(95)'] || null,
            xlarge_rps: (data.metrics.xlarge_requests?.values?.count || 0) / duration,
            xlarge_latency_p95_ms: data.metrics.xlarge_latency?.values?.['p(95)'] || null,
        },
    };

    return {
        'stdout': textSummary(data, { indent: ' ', enableColors: true }),
        [`/results/${config.targetHost}_payload.json`]: JSON.stringify(summary, null, 2),
    };
}
