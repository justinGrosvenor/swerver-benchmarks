// HTTP/2 JSON + Compression Benchmark
// Fetches /json with Accept-Encoding: gzip — exercises response compression
// over H2+TLS, HPACK encoding of Content-Encoding header, and compressed
// DATA frame throughput
import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { textSummary } from '/lib/summary.js';

const TARGET_HOST = __ENV.TARGET_HOST || 'swerver';
const TARGET_PORT = __ENV.TARGET_PORT || '8443';
const baseUrl = `https://${TARGET_HOST}:${TARGET_PORT}`;

const compressed_latency = new Trend('compressed_latency', true);
const uncompressed_latency = new Trend('uncompressed_latency', true);
const compress_errors = new Counter('compress_errors');

export const options = {
    vus: parseInt(__ENV.BENCH_VUS) || 100,
    duration: __ENV.BENCH_DURATION || '30s',
    insecureSkipTLSVerify: true,
    thresholds: {
        http_req_failed: ['rate<0.01'],
        http_reqs: ['rate>1000'],
    },
};

export default function () {
    // 80% compressed, 20% uncompressed
    if (Math.random() < 0.8) {
        const res = http.get(`${baseUrl}/json`, {
            headers: {
                Accept: 'application/json',
                'Accept-Encoding': 'gzip',
            },
            timeout: '10s',
        });
        const ok = check(res, {
            'status 200': (r) => r.status === 200,
            'is http2': (r) => r.proto === 'HTTP/2.0',
            'has json body': (r) => {
                try { JSON.parse(r.body); return true; } catch(e) { return false; }
            },
        });
        if (!ok) compress_errors.add(1);
        compressed_latency.add(res.timings.duration);
    } else {
        const res = http.get(`${baseUrl}/json`, {
            headers: {
                Accept: 'application/json',
                'Accept-Encoding': 'identity',
            },
            timeout: '10s',
        });
        const ok = check(res, {
            'status 200': (r) => r.status === 200,
            'is http2': (r) => r.proto === 'HTTP/2.0',
            'has json body': (r) => {
                try { JSON.parse(r.body); return true; } catch(e) { return false; }
            },
        });
        if (!ok) compress_errors.add(1);
        uncompressed_latency.add(res.timings.duration);
    }
}

export function handleSummary(data) {
    const metrics = data.metrics;
    const result = {
        scenario: 'h2-json-compressed',
        timestamp: new Date().toISOString(),
        server: TARGET_HOST,
        config: {
            vus: options.vus,
            duration: options.duration,
            tls: true,
            http2: true,
            mix: '80% gzip / 20% identity',
        },
        metrics: {
            requests_total: metrics.http_reqs ? metrics.http_reqs.values.count : 0,
            requests_per_second: metrics.http_reqs ? metrics.http_reqs.values.rate : 0,
            latency_avg_ms: metrics.http_req_duration ? metrics.http_req_duration.values.avg : 0,
            latency_p95_ms: metrics.http_req_duration ? metrics.http_req_duration.values['p(95)'] : 0,
            latency_p99_ms: metrics.http_req_duration ? metrics.http_req_duration.values['p(99)'] : 0,
            error_rate: metrics.http_req_failed ? metrics.http_req_failed.values.rate : 0,
            compressed_latency_avg: metrics.compressed_latency ? metrics.compressed_latency.values.avg : 0,
            uncompressed_latency_avg: metrics.uncompressed_latency ? metrics.uncompressed_latency.values.avg : 0,
            compress_errors: metrics.compress_errors ? metrics.compress_errors.values.count : 0,
        },
    };
    return {
        stdout: textSummary(data) + '\n__RESULT_JSON_START__\n' + JSON.stringify(result, null, 2) + '\n__RESULT_JSON_END__\n',
    };
}
