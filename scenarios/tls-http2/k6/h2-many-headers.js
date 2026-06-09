// HTTP/2 Header Stress Benchmark
// Sends requests with varying header counts and sizes — exercises HPACK
// encoding/decoding, dynamic table eviction, CONTINUATION frame generation,
// and header buffer limits
import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const TARGET_HOST = __ENV.TARGET_HOST || 'swerver';
const TARGET_PORT = __ENV.TARGET_PORT || '8443';
const baseUrl = `https://${TARGET_HOST}:${TARGET_PORT}`;

const few_headers_latency = new Trend('few_headers_latency', true);
const many_headers_latency = new Trend('many_headers_latency', true);
const large_header_latency = new Trend('large_header_latency', true);

function makeHeaders(count) {
    const h = { Accept: 'application/json' };
    for (let i = 0; i < count; i++) {
        h[`X-Bench-Header-${i}`] = `value-${i}-padding-${'x'.repeat(20)}`;
    }
    return h;
}

const LARGE_HEADER_VALUE = 'v'.repeat(4096);

export const options = {
    insecureSkipTLSVerify: true,
    scenarios: {
        few_headers: {
            executor: 'constant-vus',
            vus: parseInt(__ENV.BENCH_VUS) || 50,
            duration: __ENV.BENCH_DURATION || '30s',
            exec: 'fewHeaders',
        },
        many_headers: {
            executor: 'constant-vus',
            vus: 30,
            duration: __ENV.BENCH_DURATION || '30s',
            exec: 'manyHeaders',
        },
        large_header: {
            executor: 'constant-vus',
            vus: 20,
            duration: __ENV.BENCH_DURATION || '30s',
            exec: 'largeHeader',
        },
    },
    thresholds: {
        http_req_duration: ['p(95)<300', 'p(99)<600'],
        http_req_failed: ['rate<0.05'],
    },
};

export function fewHeaders() {
    const res = http.get(`${baseUrl}/echo`, {
        headers: makeHeaders(5),
        timeout: '10s',
    });
    check(res, {
        'status 200': (r) => r.status === 200,
        'is http2': (r) => r.proto === 'HTTP/2.0',
    });
    few_headers_latency.add(res.timings.duration);
}

export function manyHeaders() {
    const res = http.get(`${baseUrl}/echo`, {
        headers: makeHeaders(30),
        timeout: '10s',
    });
    check(res, {
        'status 200': (r) => r.status === 200,
    });
    many_headers_latency.add(res.timings.duration);
}

export function largeHeader() {
    const res = http.get(`${baseUrl}/echo`, {
        headers: {
            Accept: 'application/json',
            'X-Large-Header': LARGE_HEADER_VALUE,
        },
        timeout: '10s',
    });
    check(res, {
        'status 200 or 431': (r) => r.status === 200 || r.status === 431,
    });
    large_header_latency.add(res.timings.duration);
}

export function handleSummary(data) {
    const metrics = data.metrics;
    const result = {
        scenario: 'h2-many-headers',
        timestamp: new Date().toISOString(),
        server: TARGET_HOST,
        config: {
            tls: true,
            http2: true,
            header_counts: [5, 30],
            large_header_size: '4KB',
        },
        metrics: {
            requests_total: metrics.http_reqs ? metrics.http_reqs.values.count : 0,
            requests_per_second: metrics.http_reqs ? metrics.http_reqs.values.rate : 0,
            latency_avg_ms: metrics.http_req_duration ? metrics.http_req_duration.values.avg : 0,
            latency_p95_ms: metrics.http_req_duration ? metrics.http_req_duration.values['p(95)'] : 0,
            latency_p99_ms: metrics.http_req_duration ? metrics.http_req_duration.values['p(99)'] : 0,
            few_headers_p95_ms: metrics.few_headers_latency?.values?.['p(95)'] || null,
            many_headers_p95_ms: metrics.many_headers_latency?.values?.['p(95)'] || null,
            large_header_p95_ms: metrics.large_header_latency?.values?.['p(95)'] || null,
            error_rate: metrics.http_req_failed ? metrics.http_req_failed.values.rate : 0,
        },
    };
    return {
        stdout: textSummary(data) + '\n__RESULT_JSON_START__\n' + JSON.stringify(result, null, 2) + '\n__RESULT_JSON_END__\n',
    };
}
