// Error-handling performance benchmark
// Goal: Measure how efficiently servers handle invalid/error requests

import http from 'k6/http';
import { check } from 'k6';
import { Trend, Rate } from 'k6/metrics';
import { config, baseUrl, defaultParams, errorThresholds } from '/lib/helpers.js';
import { textSummary } from '/lib/summary.js';

// Per-type latency metrics
const normalLatency = new Trend('normal_latency', true);
const notFoundLatency = new Trend('not_found_latency', true);
const wrongMethodLatency = new Trend('wrong_method_latency', true);
const oversizedHeaderLatency = new Trend('oversized_header_latency', true);
const badBodyLatency = new Trend('bad_body_latency', true);

// Tracks whether each response returned an acceptable status code
const correctStatus = new Rate('correct_status');

export const options = {
    vus: config.vus,
    duration: config.duration,
    thresholds: errorThresholds,
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

// Large header value — big enough to stress header parsing but not so large
// that servers drop the connection without responding (which causes timeouts)
const bigHeaderValue = 'X'.repeat(4 * 1024);

// Shorter timeout for error requests — servers may be slow to respond to bad requests
const errorParams = {
    ...defaultParams,
    timeout: '3s',
};

export default function() {
    const rand = Math.random();
    let res;

    if (rand < 0.20) {
        // Normal request — expect 200
        res = http.get(`${baseUrl}/health`, errorParams);
        normalLatency.add(res.timings.duration);
        correctStatus.add(res.status === 200);

    } else if (rand < 0.45) {
        // 404 — nonexistent path
        res = http.get(`${baseUrl}/nonexistent/path/that/does/not/exist`, errorParams);
        notFoundLatency.add(res.timings.duration);
        // Accept 404 or 400
        correctStatus.add(res.status === 404 || res.status === 400);

    } else if (rand < 0.65) {
        // Wrong method — DELETE on /health (most servers return 405 or 400 or 404)
        res = http.del(`${baseUrl}/health`, null, errorParams);
        wrongMethodLatency.add(res.timings.duration);
        correctStatus.add(res.status === 405 || res.status === 400 || res.status === 404 || res.status === 200);

    } else if (rand < 0.85) {
        // Oversized header
        res = http.get(`${baseUrl}/health`, {
            ...errorParams,
            headers: {
                ...errorParams.headers,
                'X-Oversized': bigHeaderValue,
            },
        });
        oversizedHeaderLatency.add(res.timings.duration);
        // Accept 200 (server tolerates it), 431, 400, or 413
        correctStatus.add(res.status === 200 || res.status === 431 || res.status === 400 || res.status === 413);

    } else {
        // Bad body — POST with invalid JSON
        res = http.post(`${baseUrl}/echo`, '{{{{not json at all!!!!', {
            ...errorParams,
            headers: {
                ...errorParams.headers,
                'Content-Type': 'application/json',
            },
        });
        badBodyLatency.add(res.timings.duration);
        // Accept 200 (echo just mirrors), 400, or 422
        correctStatus.add(res.status === 200 || res.status === 400 || res.status === 422);
    }
}

export function handleSummary(data) {
    const summary = {
        scenario: 'error-handling',
        timestamp: new Date().toISOString(),
        server: config.targetHost,
        config: {
            vus: config.vus,
            duration: config.duration,
            mix: '20% normal, 25% 404, 20% wrong method, 20% oversized header, 15% bad body',
        },
        metrics: {
            requests_total: data.metrics.http_reqs.values.count,
            requests_per_second: data.metrics.http_reqs.values.rate,
            correct_status_rate: data.metrics.correct_status?.values?.rate || null,
            latency_avg_ms: data.metrics.http_req_duration.values.avg,
            latency_p95_ms: data.metrics.http_req_duration.values['p(95)'],
            latency_p99_ms: data.metrics.http_req_duration.values['p(99)'],
            // Per-type latencies
            normal_latency_avg_ms: data.metrics.normal_latency?.values?.avg || null,
            normal_latency_p95_ms: data.metrics.normal_latency?.values?.['p(95)'] || null,
            not_found_latency_avg_ms: data.metrics.not_found_latency?.values?.avg || null,
            not_found_latency_p95_ms: data.metrics.not_found_latency?.values?.['p(95)'] || null,
            wrong_method_latency_avg_ms: data.metrics.wrong_method_latency?.values?.avg || null,
            wrong_method_latency_p95_ms: data.metrics.wrong_method_latency?.values?.['p(95)'] || null,
            oversized_header_latency_avg_ms: data.metrics.oversized_header_latency?.values?.avg || null,
            oversized_header_latency_p95_ms: data.metrics.oversized_header_latency?.values?.['p(95)'] || null,
            bad_body_latency_avg_ms: data.metrics.bad_body_latency?.values?.avg || null,
            bad_body_latency_p95_ms: data.metrics.bad_body_latency?.values?.['p(95)'] || null,
        },
    };

    return {
        'stdout': textSummary(data, { indent: ' ', enableColors: true }),
        [`/results/${config.targetHost}_error-handling.json`]: JSON.stringify(summary, null, 2),
    };
}
