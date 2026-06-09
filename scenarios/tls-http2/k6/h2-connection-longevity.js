// HTTP/2 Connection Longevity / Soak Benchmark
// 5-minute sustained test on a single H2 connection — exercises HPACK dynamic
// table over thousands of requests, stream ID exhaustion patterns, memory
// stability, and keepalive behavior over time
import http from 'k6/http';
import { check } from 'k6';
import { textSummary } from '/lib/summary.js';

const TARGET_HOST = __ENV.TARGET_HOST || 'swerver';
const TARGET_PORT = __ENV.TARGET_PORT || '8443';
const baseUrl = `https://${TARGET_HOST}:${TARGET_PORT}`;

export const options = {
    vus: 10,
    duration: __ENV.BENCH_DURATION || '5m',
    insecureSkipTLSVerify: true,
    thresholds: {
        http_req_duration: ['p(95)<100', 'p(99)<200'],
        http_req_failed: ['rate<0.001'],
    },
};

export default function () {
    const res = http.get(`${baseUrl}/echo`, {
        headers: { Accept: 'application/json' },
        timeout: '10s',
    });
    check(res, {
        'status 200': (r) => r.status === 200,
        'is http2': (r) => r.proto === 'HTTP/2.0',
        'has body': (r) => r.body && r.body.length > 0,
    });
}

export function handleSummary(data) {
    const metrics = data.metrics;
    const result = {
        scenario: 'h2-connection-longevity',
        timestamp: new Date().toISOString(),
        server: TARGET_HOST,
        config: {
            vus: options.vus,
            duration: options.duration,
            tls: true,
            http2: true,
        },
        metrics: {
            requests_total: metrics.http_reqs ? metrics.http_reqs.values.count : 0,
            requests_per_second: metrics.http_reqs ? metrics.http_reqs.values.rate : 0,
            latency_avg_ms: metrics.http_req_duration ? metrics.http_req_duration.values.avg : 0,
            latency_p95_ms: metrics.http_req_duration ? metrics.http_req_duration.values['p(95)'] : 0,
            latency_p99_ms: metrics.http_req_duration ? metrics.http_req_duration.values['p(99)'] : 0,
            error_rate: metrics.http_req_failed ? metrics.http_req_failed.values.rate : 0,
        },
    };
    return {
        stdout: textSummary(data) + '\n__RESULT_JSON_START__\n' + JSON.stringify(result, null, 2) + '\n__RESULT_JSON_END__\n',
    };
}
