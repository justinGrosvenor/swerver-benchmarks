// HTTP/2 Static File Benchmark
// Fetches static files of varying sizes over H2+TLS — exercises multi-frame
// DATA packing, buffer pool pressure under multiplexed file streams, and
// flow control with real disk I/O
import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const TARGET_HOST = __ENV.TARGET_HOST || 'swerver';
const TARGET_PORT = __ENV.TARGET_PORT || '8443';
const baseUrl = `https://${TARGET_HOST}:${TARGET_PORT}`;

const small_latency = new Trend('small_file_latency', true);
const medium_latency = new Trend('medium_file_latency', true);
const large_latency = new Trend('large_file_latency', true);
const error_count = new Counter('file_errors');

const FILES = [
    { path: '/static/small.txt',  size: 1024,   label: 'small' },
    { path: '/static/medium.css', size: 32768,   label: 'medium' },
    { path: '/static/large.js',   size: 131072,  label: 'large' },
    { path: '/static/image.bin',  size: 524288,  label: 'xlarge' },
];

export const options = {
    vus: parseInt(__ENV.BENCH_VUS) || 100,
    duration: __ENV.BENCH_DURATION || '30s',
    insecureSkipTLSVerify: true,
    thresholds: {
        http_req_failed: ['rate<0.01'],
        http_reqs: ['rate>500'],
    },
};

export default function () {
    const file = FILES[Math.floor(Math.random() * FILES.length)];
    const res = http.get(`${baseUrl}${file.path}`, {
        timeout: '15s',
        responseType: 'binary',
    });
    const bodyLen = res.body ? (res.body.byteLength || res.body.length || 0) : 0;
    const ok = check(res, {
        'status 200': (r) => r.status === 200,
        'is http2': (r) => r.proto === 'HTTP/2.0',
        'has body': () => bodyLen > 0,
        'body size correct': () => bodyLen === file.size,
    });
    if (!ok) error_count.add(1);
    if (file.label === 'small') small_latency.add(res.timings.duration);
    else if (file.label === 'medium') medium_latency.add(res.timings.duration);
    else large_latency.add(res.timings.duration);
}

export function handleSummary(data) {
    const metrics = data.metrics;
    const result = {
        scenario: 'h2-static-files',
        timestamp: new Date().toISOString(),
        server: TARGET_HOST,
        config: {
            vus: options.vus,
            duration: options.duration,
            tls: true,
            http2: true,
            file_sizes: '1KB-512KB mixed',
        },
        metrics: {
            requests_total: metrics.http_reqs ? metrics.http_reqs.values.count : 0,
            requests_per_second: metrics.http_reqs ? metrics.http_reqs.values.rate : 0,
            latency_avg_ms: metrics.http_req_duration ? metrics.http_req_duration.values.avg : 0,
            latency_p95_ms: metrics.http_req_duration ? metrics.http_req_duration.values['p(95)'] : 0,
            latency_p99_ms: metrics.http_req_duration ? metrics.http_req_duration.values['p(99)'] : 0,
            error_rate: metrics.http_req_failed ? metrics.http_req_failed.values.rate : 0,
            small_latency_avg: metrics.small_file_latency ? metrics.small_file_latency.values.avg : 0,
            medium_latency_avg: metrics.medium_file_latency ? metrics.medium_file_latency.values.avg : 0,
            large_latency_avg: metrics.large_file_latency ? metrics.large_file_latency.values.avg : 0,
            file_errors: metrics.file_errors ? metrics.file_errors.values.count : 0,
        },
    };
    return {
        stdout: textSummary(data) + '\n__RESULT_JSON_START__\n' + JSON.stringify(result, null, 2) + '\n__RESULT_JSON_END__\n',
    };
}
