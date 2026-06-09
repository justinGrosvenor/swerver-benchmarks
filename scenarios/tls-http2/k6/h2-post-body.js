// HTTP/2 POST Body Benchmark
// Tests POST bodies at multiple sizes over H2 — exercises DATA frame splitting,
// TCP-read-spanning DATA frames, and HPACK encoding of content-length
import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const TARGET_HOST = __ENV.TARGET_HOST || 'swerver';
const TARGET_PORT = __ENV.TARGET_PORT || '8443';
const baseUrl = `https://${TARGET_HOST}:${TARGET_PORT}`;

const small_latency = new Trend('small_body_latency', true);
const medium_latency = new Trend('medium_body_latency', true);
const large_latency = new Trend('large_body_latency', true);
const xlarge_latency = new Trend('xlarge_body_latency', true);

const small_count = new Counter('small_body_requests');
const medium_count = new Counter('medium_body_requests');
const large_count = new Counter('large_body_requests');
const xlarge_count = new Counter('xlarge_body_requests');

const SMALL_BODY = 'x'.repeat(512);
const MEDIUM_BODY = 'x'.repeat(8 * 1024);
const LARGE_BODY = 'x'.repeat(32 * 1024);
const XLARGE_BODY = 'x'.repeat(128 * 1024);

const postParams = {
    headers: { 'Content-Type': 'application/octet-stream' },
    timeout: '10s',
};

export const options = {
    insecureSkipTLSVerify: true,
    scenarios: {
        small: {
            executor: 'constant-vus',
            vus: 20,
            duration: __ENV.BENCH_DURATION || '30s',
            exec: 'postSmall',
        },
        medium: {
            executor: 'constant-vus',
            vus: 20,
            duration: __ENV.BENCH_DURATION || '30s',
            exec: 'postMedium',
        },
        large: {
            executor: 'constant-vus',
            vus: 20,
            duration: __ENV.BENCH_DURATION || '30s',
            exec: 'postLarge',
        },
        xlarge: {
            executor: 'constant-vus',
            vus: 20,
            duration: __ENV.BENCH_DURATION || '30s',
            exec: 'postXlarge',
        },
    },
    thresholds: {
        http_req_duration: ['p(95)<500'],
        http_req_failed: ['rate<0.05'],
    },
};

export function postSmall() {
    const res = http.post(`${baseUrl}/echo`, SMALL_BODY, postParams);
    check(res, {
        'status 200': (r) => r.status === 200,
        'is http2': (r) => r.proto === 'HTTP/2.0',
    });
    small_latency.add(res.timings.duration);
    small_count.add(1);
}

export function postMedium() {
    const res = http.post(`${baseUrl}/echo`, MEDIUM_BODY, postParams);
    check(res, {
        'status 200': (r) => r.status === 200,
        'body echoed': (r) => r.body && r.body.length === MEDIUM_BODY.length,
    });
    medium_latency.add(res.timings.duration);
    medium_count.add(1);
}

export function postLarge() {
    const res = http.post(`${baseUrl}/echo`, LARGE_BODY, postParams);
    check(res, {
        'status 200': (r) => r.status === 200,
        'body echoed': (r) => r.body && r.body.length === LARGE_BODY.length,
    });
    large_latency.add(res.timings.duration);
    large_count.add(1);
}

export function postXlarge() {
    const res = http.post(`${baseUrl}/echo`, XLARGE_BODY, postParams);
    check(res, {
        'status 200': (r) => r.status === 200,
        'body echoed': (r) => r.body && r.body.length === XLARGE_BODY.length,
    });
    xlarge_latency.add(res.timings.duration);
    xlarge_count.add(1);
}

export function handleSummary(data) {
    const dur = parseInt(__ENV.BENCH_DURATION) || 30;
    const metrics = data.metrics;
    const result = {
        scenario: 'h2-post-body',
        timestamp: new Date().toISOString(),
        server: TARGET_HOST,
        config: {
            vus_per_size: 20,
            duration: __ENV.BENCH_DURATION || '30s',
            tls: true,
            http2: true,
            sizes: ['512B', '8KB', '32KB', '128KB'],
        },
        metrics: {
            requests_total: metrics.http_reqs ? metrics.http_reqs.values.count : 0,
            requests_per_second: metrics.http_reqs ? metrics.http_reqs.values.rate : 0,
            latency_avg_ms: metrics.http_req_duration ? metrics.http_req_duration.values.avg : 0,
            latency_p95_ms: metrics.http_req_duration ? metrics.http_req_duration.values['p(95)'] : 0,
            latency_p99_ms: metrics.http_req_duration ? metrics.http_req_duration.values['p(99)'] : 0,
            error_rate: metrics.http_req_failed ? metrics.http_req_failed.values.rate : 0,
            small_rps: (metrics.small_body_requests?.values?.count || 0) / dur,
            small_p95_ms: metrics.small_body_latency?.values?.['p(95)'] || null,
            medium_rps: (metrics.medium_body_requests?.values?.count || 0) / dur,
            medium_p95_ms: metrics.medium_body_latency?.values?.['p(95)'] || null,
            large_rps: (metrics.large_body_requests?.values?.count || 0) / dur,
            large_p95_ms: metrics.large_body_latency?.values?.['p(95)'] || null,
            xlarge_rps: (metrics.xlarge_body_requests?.values?.count || 0) / dur,
            xlarge_p95_ms: metrics.xlarge_body_latency?.values?.['p(95)'] || null,
        },
    };
    return {
        stdout: textSummary(data) + '\n__RESULT_JSON_START__\n' + JSON.stringify(result, null, 2) + '\n__RESULT_JSON_END__\n',
    };
}
