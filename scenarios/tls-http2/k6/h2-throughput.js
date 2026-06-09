// HTTP/2 Throughput Benchmark
// Measures HTTP/2 multiplexed request throughput over TLS
// k6 automatically uses HTTP/2 when the server supports it via ALPN
import http from 'k6/http';
import { check } from 'k6';
import { textSummary } from '/lib/summary.js';

const TARGET_HOST = __ENV.TARGET_HOST || 'swerver';
const TARGET_PORT = __ENV.TARGET_PORT || '8443';
const baseUrl = `https://${TARGET_HOST}:${TARGET_PORT}`;

export const options = {
    vus: parseInt(__ENV.BENCH_VUS) || 100,
    duration: __ENV.BENCH_DURATION || '30s',
    insecureSkipTLSVerify: true,
    thresholds: {
        http_req_duration: ['p(95)<100', 'p(99)<200'],
        http_req_failed: ['rate<0.01'],
        http_reqs: ['rate>1000'],
    },
};

export default function () {
    const res = http.get(`${baseUrl}/echo`, {
        headers: { Accept: 'application/json' },
        timeout: '10s',
    });
    check(res, {
        'status 200': (r) => r.status === 200,
        'has body': (r) => r.body && r.body.length > 0,
        'is http2': (r) => r.proto === 'HTTP/2.0',
    });
}

export function handleSummary(data) {
    const metrics = data.metrics;
    const result = {
        scenario: 'h2-throughput',
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
            tls_handshaking_avg_ms: metrics.http_req_tls_handshaking ? metrics.http_req_tls_handshaking.values.avg : 0,
            error_rate: metrics.http_req_failed ? metrics.http_req_failed.values.rate : 0,
        },
    };
    return {
        stdout: textSummary(data) + '\n__RESULT_JSON_START__\n' + JSON.stringify(result, null, 2) + '\n__RESULT_JSON_END__\n',
    };
}
