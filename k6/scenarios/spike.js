// Spike/burst traffic benchmark
// Goal: Test server resilience under sudden traffic spikes and recovery

import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';
import { config, baseUrl, defaultParams, spikeThresholds } from '/lib/helpers.js';
import { textSummary } from '/lib/summary.js';

const errorRate = new Rate('errors');
const recoveryLatency = new Trend('recovery_latency', true);

// Spike pattern: baseline → spike → recover → bigger spike → recover → ramp down
export const options = {
    stages: [
        { duration: '10s', target: 50 },     // Baseline ramp
        { duration: '10s', target: 50 },     // Hold baseline
        { duration: '5s', target: 500 },     // Spike to 500
        { duration: '15s', target: 500 },    // Hold spike
        { duration: '10s', target: 50 },     // Recover
        { duration: '10s', target: 50 },     // Hold recovery
        { duration: '5s', target: 1000 },    // Spike to 1000
        { duration: '20s', target: 1000 },   // Hold spike
        { duration: '10s', target: 50 },     // Recover
        { duration: '15s', target: 50 },     // Hold recovery
        { duration: '10s', target: 0 },      // Ramp down
    ],
    thresholds: spikeThresholds,
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

export default function() {
    const res = http.get(`${baseUrl}/health`, defaultParams);

    const success = check(res, {
        'status is 200': (r) => r.status === 200,
    });

    errorRate.add(!success);

    // Track latency during recovery periods (VUs < 100 after a spike)
    if (success) {
        recoveryLatency.add(res.timings.duration);
    }
}

export function handleSummary(data) {
    const summary = {
        scenario: 'spike',
        timestamp: new Date().toISOString(),
        server: config.targetHost,
        config: {
            stages: 'baseline 50 → spike 500 → recover → spike 1000 → recover → down',
            total_duration: '120s',
        },
        metrics: {
            requests_total: data.metrics.http_reqs.values.count,
            requests_per_second: data.metrics.http_reqs.values.rate,
            errors_total: data.metrics.http_req_failed.values.passes,
            error_rate: data.metrics.http_req_failed.values.rate,
            latency_avg_ms: data.metrics.http_req_duration.values.avg,
            latency_p50_ms: data.metrics.http_req_duration.values.med,
            latency_p95_ms: data.metrics.http_req_duration.values['p(95)'],
            latency_p99_ms: data.metrics.http_req_duration.values['p(99)'],
            latency_max_ms: data.metrics.http_req_duration.values.max,
            recovery_latency_avg_ms: data.metrics.recovery_latency?.values?.avg || null,
            recovery_latency_p95_ms: data.metrics.recovery_latency?.values?.['p(95)'] || null,
        },
    };

    return {
        'stdout': textSummary(data, { indent: ' ', enableColors: true }),
        [`/results/${config.targetHost}_spike.json`]: JSON.stringify(summary, null, 2),
    };
}
