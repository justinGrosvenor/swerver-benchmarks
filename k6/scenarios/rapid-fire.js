// Rapid-fire maximum capacity benchmark
// Goal: Find the absolute ceiling — 200 VUs, zero think time, minimal endpoint

import http from 'k6/http';
import { check } from 'k6';
import { Rate, Counter } from 'k6/metrics';
import { config, baseUrl, defaultParams } from '/lib/helpers.js';
import { textSummary } from '/lib/summary.js';

const errorRate = new Rate('errors');
const timeoutRate = new Rate('timeouts');
const requestsTotal = new Counter('requests_total');

export const options = {
    vus: 200,
    duration: '30s',
    thresholds: {
        http_req_duration: ['p(95)<500'],
        http_req_failed: ['rate<0.10'],
        http_reqs: ['rate>5000'],
    },
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)', 'p(99.9)'],
};

export default function() {
    const res = http.get(`${baseUrl}/health`, defaultParams);

    const success = check(res, {
        'status is 200': (r) => r.status === 200,
    });

    errorRate.add(!success);
    timeoutRate.add(res.timings.duration >= 10000); // 10s timeout
    requestsTotal.add(1);
}

export function handleSummary(data) {
    const summary = {
        scenario: 'rapid-fire',
        timestamp: new Date().toISOString(),
        server: config.targetHost,
        config: {
            vus: 200,
            duration: '30s',
            think_time: 'none',
        },
        metrics: {
            requests_total: data.metrics.http_reqs.values.count,
            requests_per_second: data.metrics.http_reqs.values.rate,
            errors_total: data.metrics.http_req_failed.values.passes,
            error_rate: data.metrics.http_req_failed.values.rate,
            timeout_rate: data.metrics.timeouts?.values?.rate || 0,
            latency_avg_ms: data.metrics.http_req_duration.values.avg,
            latency_p50_ms: data.metrics.http_req_duration.values.med,
            latency_p95_ms: data.metrics.http_req_duration.values['p(95)'],
            latency_p99_ms: data.metrics.http_req_duration.values['p(99)'],
            latency_p999_ms: data.metrics.http_req_duration.values['p(99.9)'],
            latency_max_ms: data.metrics.http_req_duration.values.max,
        },
    };

    return {
        'stdout': textSummary(data, { indent: ' ', enableColors: true }),
        [`/results/${config.targetHost}_rapid-fire.json`]: JSON.stringify(summary, null, 2),
    };
}
