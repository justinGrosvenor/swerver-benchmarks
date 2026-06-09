// HTTP/2 Concurrent Streams Benchmark
// Ramps VUs from 50 to 500 to stress stream management at scale — exercises
// stream ID allocation, priority handling, flow control windows, and cleanup
// under heavy multiplexing
import http from 'k6/http';
import { check } from 'k6';
import { textSummary } from '/lib/summary.js';

const TARGET_HOST = __ENV.TARGET_HOST || 'swerver';
const TARGET_PORT = __ENV.TARGET_PORT || '8443';
const baseUrl = `https://${TARGET_HOST}:${TARGET_PORT}`;

export const options = {
    insecureSkipTLSVerify: true,
    scenarios: {
        ramp: {
            executor: 'ramping-vus',
            startVUs: 50,
            stages: [
                { duration: '10s', target: 50 },
                { duration: '20s', target: 200 },
                { duration: '20s', target: 500 },
                { duration: '10s', target: 500 },
                { duration: '10s', target: 50 },
            ],
        },
    },
    thresholds: {
        http_req_duration: ['p(95)<500', 'p(99)<1000'],
        http_req_failed: ['rate<0.05'],
    },
};

export default function () {
    const res = http.get(`${baseUrl}/echo`, {
        headers: { Accept: 'application/json' },
        timeout: '15s',
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
        scenario: 'h2-concurrent-streams',
        timestamp: new Date().toISOString(),
        server: TARGET_HOST,
        config: {
            tls: true,
            http2: true,
            stages: '50→200→500→500→50 VUs',
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
