// HTTP/2 Multiplexing Benchmark
// Uses http.batch() to send concurrent requests on a single H2 connection —
// exercises stream multiplexing, HPACK dynamic table under parallel encodes,
// and max_concurrent_streams enforcement
import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const TARGET_HOST = __ENV.TARGET_HOST || 'swerver';
const TARGET_PORT = __ENV.TARGET_PORT || '8443';
const baseUrl = `https://${TARGET_HOST}:${TARGET_PORT}`;

const batch10_latency = new Trend('batch10_latency', true);
const batch50_latency = new Trend('batch50_latency', true);

function makeBatch(n) {
    const reqs = [];
    for (let i = 0; i < n; i++) {
        reqs.push(['GET', `${baseUrl}/echo?stream=${i}`, null, {
            headers: { Accept: 'application/json' },
            timeout: '15s',
        }]);
    }
    return reqs;
}

export const options = {
    insecureSkipTLSVerify: true,
    scenarios: {
        batch10: {
            executor: 'constant-vus',
            vus: parseInt(__ENV.BENCH_VUS) || 50,
            duration: __ENV.BENCH_DURATION || '30s',
            exec: 'runBatch10',
        },
        batch50: {
            executor: 'constant-vus',
            vus: 10,
            duration: __ENV.BENCH_DURATION || '30s',
            exec: 'runBatch50',
        },
    },
    thresholds: {
        http_req_duration: ['p(95)<300', 'p(99)<600'],
        http_req_failed: ['rate<0.02'],
    },
};

export function runBatch10() {
    const start = Date.now();
    const responses = http.batch(makeBatch(10));
    const elapsed = Date.now() - start;
    batch10_latency.add(elapsed);

    for (const res of responses) {
        check(res, {
            'status 200': (r) => r.status === 200,
            'is http2': (r) => r.proto === 'HTTP/2.0',
        });
    }
}

export function runBatch50() {
    const start = Date.now();
    const responses = http.batch(makeBatch(50));
    const elapsed = Date.now() - start;
    batch50_latency.add(elapsed);

    for (const res of responses) {
        check(res, {
            'status 200': (r) => r.status === 200,
        });
    }
}

export function handleSummary(data) {
    const metrics = data.metrics;
    const result = {
        scenario: 'h2-multiplexing',
        timestamp: new Date().toISOString(),
        server: TARGET_HOST,
        config: {
            tls: true,
            http2: true,
            batch_sizes: [10, 50],
        },
        metrics: {
            requests_total: metrics.http_reqs ? metrics.http_reqs.values.count : 0,
            requests_per_second: metrics.http_reqs ? metrics.http_reqs.values.rate : 0,
            latency_avg_ms: metrics.http_req_duration ? metrics.http_req_duration.values.avg : 0,
            latency_p95_ms: metrics.http_req_duration ? metrics.http_req_duration.values['p(95)'] : 0,
            latency_p99_ms: metrics.http_req_duration ? metrics.http_req_duration.values['p(99)'] : 0,
            batch10_avg_ms: metrics.batch10_latency ? metrics.batch10_latency.values.avg : null,
            batch10_p95_ms: metrics.batch10_latency ? metrics.batch10_latency.values['p(95)'] : null,
            batch50_avg_ms: metrics.batch50_latency ? metrics.batch50_latency.values.avg : null,
            batch50_p95_ms: metrics.batch50_latency ? metrics.batch50_latency.values['p(95)'] : null,
            error_rate: metrics.http_req_failed ? metrics.http_req_failed.values.rate : 0,
        },
    };
    return {
        stdout: textSummary(data) + '\n__RESULT_JSON_START__\n' + JSON.stringify(result, null, 2) + '\n__RESULT_JSON_END__\n',
    };
}
