// Latency distribution benchmark
// Goal: Measure response time percentiles under moderate load

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';
import { config, baseUrl, defaultParams } from '/lib/helpers.js';
import { textSummary } from '/lib/summary.js';

const errorRate = new Rate('errors');

export const options = {
    vus: Math.min(config.vus, 50), // Moderate load for accurate latency
    duration: config.duration,
    thresholds: {
        http_req_duration: ['p(50)<10', 'p(90)<25', 'p(95)<50', 'p(99)<100'],
        http_req_failed: ['rate<0.01'],
    },
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(75)', 'p(90)', 'p(95)', 'p(99)', 'p(99.9)'],
};

export default function() {
    const res = http.get(`${baseUrl}/echo`, {
        ...defaultParams,
        headers: {
            ...defaultParams.headers,
            'Accept': 'application/json',
        },
    });

    const success = check(res, {
        'status is 200': (r) => r.status === 200,
        'body is valid json': (r) => {
            try {
                JSON.parse(r.body);
                return true;
            } catch {
                return false;
            }
        },
    });

    errorRate.add(!success);

    // Small think time for more realistic latency measurement
    sleep(0.01);
}

export function handleSummary(data) {
    const summary = {
        scenario: 'latency',
        timestamp: new Date().toISOString(),
        server: config.targetHost,
        config: {
            vus: Math.min(config.vus, 50),
            duration: config.duration,
        },
        metrics: {
            requests_total: data.metrics.http_reqs.values.count,
            requests_per_second: data.metrics.http_reqs.values.rate,
            errors_total: data.metrics.http_req_failed.values.passes, // passes = requests where failed=true
            error_rate: data.metrics.http_req_failed.values.rate,
            latency_avg_ms: data.metrics.http_req_duration.values.avg,
            latency_min_ms: data.metrics.http_req_duration.values.min,
            latency_p50_ms: data.metrics.http_req_duration.values['p(50)'],
            latency_p75_ms: data.metrics.http_req_duration.values['p(75)'],
            latency_p90_ms: data.metrics.http_req_duration.values['p(90)'],
            latency_p95_ms: data.metrics.http_req_duration.values['p(95)'],
            latency_p99_ms: data.metrics.http_req_duration.values['p(99)'],
            latency_p999_ms: data.metrics.http_req_duration.values['p(99.9)'],
            latency_max_ms: data.metrics.http_req_duration.values.max,
        },
    };

    return {
        'stdout': textSummary(data, { indent: ' ', enableColors: true }),
        '/results/latency.json': JSON.stringify(summary, null, 2),
    };
}
