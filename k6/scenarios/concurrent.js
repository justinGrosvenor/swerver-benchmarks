// Concurrent connections scaling benchmark
// Goal: Test how throughput scales with increasing connections

import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';
import { config, baseUrl, defaultParams } from '/lib/helpers.js';
import { textSummary } from '/lib/summary.js';

const errorRate = new Rate('errors');

// Ramping stages: 10 -> 100 -> 500 -> 1000 VUs
export const options = {
    stages: [
        { duration: '10s', target: 10 },     // Warmup
        { duration: '20s', target: 100 },    // Ramp to 100
        { duration: '20s', target: 100 },    // Hold at 100
        { duration: '20s', target: 500 },    // Ramp to 500
        { duration: '20s', target: 500 },    // Hold at 500
        { duration: '20s', target: 1000 },   // Ramp to 1000
        { duration: '30s', target: 1000 },   // Hold at 1000
        { duration: '10s', target: 0 },      // Ramp down
    ],
    thresholds: {
        http_req_duration: ['p(95)<500'],
        http_req_failed: ['rate<0.05'],
    },
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

export default function() {
    const res = http.get(`${baseUrl}/health`, defaultParams);

    const success = check(res, {
        'status is 200': (r) => r.status === 200,
    });

    errorRate.add(!success);
}

export function handleSummary(data) {
    const summary = {
        scenario: 'concurrent',
        timestamp: new Date().toISOString(),
        server: config.targetHost,
        config: {
            stages: 'ramp 10->100->500->1000',
            total_duration: '150s',
        },
        metrics: {
            requests_total: data.metrics.http_reqs.values.count,
            requests_per_second_avg: data.metrics.http_reqs.values.rate,
            errors_total: data.metrics.http_req_failed.values.passes, // passes = requests where failed=true
            error_rate: data.metrics.http_req_failed.values.rate,
            latency_avg_ms: data.metrics.http_req_duration.values.avg,
            latency_p50_ms: data.metrics.http_req_duration.values.med,
            latency_p95_ms: data.metrics.http_req_duration.values['p(95)'],
            latency_p99_ms: data.metrics.http_req_duration.values['p(99)'],
            latency_max_ms: data.metrics.http_req_duration.values.max,
            vus_max: data.metrics.vus_max?.values?.value || 1000,
        },
    };

    return {
        'stdout': textSummary(data, { indent: ' ', enableColors: true }),
        [`/results/${config.targetHost}_concurrent.json`]: JSON.stringify(summary, null, 2),
    };
}
