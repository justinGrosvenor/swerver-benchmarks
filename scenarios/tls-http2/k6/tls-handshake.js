// TLS Handshake Benchmark
// Measures TLS connection setup overhead by forcing new connections (Connection: close)
import http from 'k6/http';
import { check } from 'k6';
import { textSummary } from '/lib/summary.js';

const TARGET_HOST = __ENV.TARGET_HOST || 'swerver';
const TARGET_PORT = __ENV.TARGET_PORT || '8443';
const baseUrl = `https://${TARGET_HOST}:${TARGET_PORT}`;

export const options = {
    vus: parseInt(__ENV.K6_VUS) || 100,
    duration: __ENV.K6_DURATION || '30s',
    insecureSkipTLSVerify: true,
    noConnectionReuse: true,
    thresholds: {
        http_req_duration: ['p(95)<500', 'p(99)<1000'],
        http_req_failed: ['rate<0.05'],
    },
};

export default function () {
    const res = http.get(`${baseUrl}/health`, {
        headers: {
            Accept: 'application/json',
            Connection: 'close',
        },
        timeout: '10s',
    });
    check(res, {
        'status 200': (r) => r.status === 200,
    });
}

export function handleSummary(data) {
    const metrics = data.metrics;
    const result = {
        scenario: 'tls-handshake',
        timestamp: new Date().toISOString(),
        server: TARGET_HOST,
        config: {
            vus: options.vus,
            duration: options.duration,
            tls: true,
            connection_reuse: false,
        },
        metrics: {
            connections_total: metrics.http_reqs ? metrics.http_reqs.values.count : 0,
            connections_per_second: metrics.http_reqs ? metrics.http_reqs.values.rate : 0,
            latency_avg_ms: metrics.http_req_duration ? metrics.http_req_duration.values.avg : 0,
            latency_p95_ms: metrics.http_req_duration ? metrics.http_req_duration.values['p(95)'] : 0,
            latency_p99_ms: metrics.http_req_duration ? metrics.http_req_duration.values['p(99)'] : 0,
            tls_handshaking_avg_ms: metrics.http_req_tls_handshaking ? metrics.http_req_tls_handshaking.values.avg : 0,
            tls_handshaking_p95_ms: metrics.http_req_tls_handshaking ? metrics.http_req_tls_handshaking.values['p(95)'] : 0,
            tls_handshaking_p99_ms: metrics.http_req_tls_handshaking ? metrics.http_req_tls_handshaking.values['p(99)'] : 0,
            connecting_avg_ms: metrics.http_req_connecting ? metrics.http_req_connecting.values.avg : 0,
            error_rate: metrics.http_req_failed ? metrics.http_req_failed.values.rate : 0,
        },
    };
    return {
        [`/results/${TARGET_HOST}_tls-handshake.json`]: JSON.stringify(result, null, 2),
        stdout: textSummary(data),
    };
}
