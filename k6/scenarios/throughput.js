// Throughput benchmark
// Goal: Maximum requests per second on minimal endpoint

import http from 'k6/http';
import { check } from 'k6';
import { Rate, Counter } from 'k6/metrics';
import { config, baseUrl, defaultParams, standardThresholds } from '/lib/helpers.js';
import { textSummary } from '/lib/summary.js';

// Custom metrics
const errorRate = new Rate('errors');
const requestsTotal = new Counter('requests_total');

export const options = {
    vus: config.vus,
    duration: config.duration,
    thresholds: standardThresholds,
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

export default function() {
    const res = http.get(`${baseUrl}/health`, defaultParams);

    const success = check(res, {
        'status is 200': (r) => r.status === 200,
    });

    errorRate.add(!success);
    requestsTotal.add(1);
}

export function handleSummary(data) {
    const summary = {
        scenario: 'throughput',
        timestamp: new Date().toISOString(),
        server: config.targetHost,
        config: {
            vus: config.vus,
            duration: config.duration,
        },
        metrics: {
            requests_total: data.metrics.http_reqs.values.count,
            requests_per_second: data.metrics.http_reqs.values.rate,
            errors_total: data.metrics.http_req_failed.values.passes,
            error_rate: data.metrics.http_req_failed.values.rate,
            latency_avg_ms: data.metrics.http_req_duration.values.avg,
            latency_min_ms: data.metrics.http_req_duration.values.min,
            latency_med_ms: data.metrics.http_req_duration.values.med,
            latency_p90_ms: data.metrics.http_req_duration.values['p(90)'],
            latency_p95_ms: data.metrics.http_req_duration.values['p(95)'],
            latency_p99_ms: data.metrics.http_req_duration.values['p(99)'],
            latency_max_ms: data.metrics.http_req_duration.values.max,
        },
    };

    return {
        'stdout': textSummary(data, { indent: ' ', enableColors: true }),
        '/results/throughput.json': JSON.stringify(summary, null, 2),
    };
}
