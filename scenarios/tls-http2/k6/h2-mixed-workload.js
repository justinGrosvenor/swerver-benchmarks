// HTTP/2 Mixed Workload Benchmark
// Comprehensive weighted workload exercising multiple H2 code paths
// simultaneously — GET, POST, large response, many headers, batch requests.
// This is the integration/regression scenario: if any single code path
// has a bug that surfaces under interleaved traffic, this catches it.
import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const TARGET_HOST = __ENV.TARGET_HOST || 'swerver';
const TARGET_PORT = __ENV.TARGET_PORT || '8443';
const baseUrl = `https://${TARGET_HOST}:${TARGET_PORT}`;

const get_latency = new Trend('get_latency', true);
const post_latency = new Trend('post_latency', true);
const blob_latency = new Trend('blob_latency', true);
const batch_latency = new Trend('batch_latency', true);

const POST_BODY = 'x'.repeat(16 * 1024);

export const options = {
    insecureSkipTLSVerify: true,
    scenarios: {
        gets: {
            executor: 'constant-vus',
            vus: 40,
            duration: __ENV.BENCH_DURATION || '30s',
            exec: 'doGet',
        },
        posts: {
            executor: 'constant-vus',
            vus: 20,
            duration: __ENV.BENCH_DURATION || '30s',
            exec: 'doPost',
        },
        blobs: {
            executor: 'constant-vus',
            vus: 20,
            duration: __ENV.BENCH_DURATION || '30s',
            exec: 'doBlob',
        },
        batches: {
            executor: 'constant-vus',
            vus: 10,
            duration: __ENV.BENCH_DURATION || '30s',
            exec: 'doBatch',
        },
    },
    thresholds: {
        http_req_duration: ['p(95)<300', 'p(99)<600'],
        http_req_failed: ['rate<0.02'],
    },
};

export function doGet() {
    const res = http.get(`${baseUrl}/echo`, {
        headers: {
            Accept: 'application/json',
            'X-Request-Id': `get-${__VU}-${__ITER}`,
        },
        timeout: '10s',
    });
    check(res, {
        'GET 200': (r) => r.status === 200,
        'is http2': (r) => r.proto === 'HTTP/2.0',
    });
    get_latency.add(res.timings.duration);
}

export function doPost() {
    const res = http.post(`${baseUrl}/echo`, POST_BODY, {
        headers: { 'Content-Type': 'application/octet-stream' },
        timeout: '10s',
    });
    check(res, {
        'POST 200': (r) => r.status === 200,
        'body echoed': (r) => r.body && r.body.length === POST_BODY.length,
    });
    post_latency.add(res.timings.duration);
}

export function doBlob() {
    const res = http.get(`${baseUrl}/blob`, {
        timeout: '10s',
        responseType: 'binary',
    });
    check(res, {
        'blob 200': (r) => r.status === 200,
        'blob size': (r) => r.body && r.body.length >= 8000,
    });
    blob_latency.add(res.timings.duration);
}

export function doBatch() {
    const reqs = [];
    for (let i = 0; i < 10; i++) {
        reqs.push(['GET', `${baseUrl}/echo?b=${i}`, null, {
            headers: { Accept: 'application/json' },
            timeout: '15s',
        }]);
    }
    const start = Date.now();
    const responses = http.batch(reqs);
    batch_latency.add(Date.now() - start);

    for (const res of responses) {
        check(res, { 'batch 200': (r) => r.status === 200 });
    }
}

export function handleSummary(data) {
    const metrics = data.metrics;
    const result = {
        scenario: 'h2-mixed-workload',
        timestamp: new Date().toISOString(),
        server: TARGET_HOST,
        config: {
            tls: true,
            http2: true,
            workload: 'GET(40VU) + POST(20VU) + blob(20VU) + batch(10VU)',
        },
        metrics: {
            requests_total: metrics.http_reqs ? metrics.http_reqs.values.count : 0,
            requests_per_second: metrics.http_reqs ? metrics.http_reqs.values.rate : 0,
            latency_avg_ms: metrics.http_req_duration ? metrics.http_req_duration.values.avg : 0,
            latency_p95_ms: metrics.http_req_duration ? metrics.http_req_duration.values['p(95)'] : 0,
            latency_p99_ms: metrics.http_req_duration ? metrics.http_req_duration.values['p(99)'] : 0,
            get_p95_ms: metrics.get_latency?.values?.['p(95)'] || null,
            post_p95_ms: metrics.post_latency?.values?.['p(95)'] || null,
            blob_p95_ms: metrics.blob_latency?.values?.['p(95)'] || null,
            batch_p95_ms: metrics.batch_latency?.values?.['p(95)'] || null,
            error_rate: metrics.http_req_failed ? metrics.http_req_failed.values.rate : 0,
        },
    };
    return {
        stdout: textSummary(data) + '\n__RESULT_JSON_START__\n' + JSON.stringify(result, null, 2) + '\n__RESULT_JSON_END__\n',
    };
}
