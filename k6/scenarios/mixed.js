// Mixed workload benchmark
// Goal: Simulate realistic traffic patterns

import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';
import { config, baseUrl, defaultParams, randomJsonBody } from '/lib/helpers.js';
import { textSummary } from '/lib/summary.js';

const errorRate = new Rate('errors');

export const options = {
    vus: config.vus,
    duration: config.duration,
    thresholds: {
        http_req_duration: ['p(95)<200', 'p(99)<500'],
        http_req_failed: ['rate<0.02'],
    },
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

// Workload distribution
const WORKLOAD = {
    health: 0.30,      // 30% health checks
    echoGet: 0.40,     // 40% GET /echo
    echoPost: 0.20,    // 20% POST /echo with body
    blob: 0.10,        // 10% large response
};

export default function() {
    const rand = Math.random();
    let res;

    if (rand < WORKLOAD.health) {
        // Health check
        res = http.get(`${baseUrl}/health`, defaultParams);
    } else if (rand < WORKLOAD.health + WORKLOAD.echoGet) {
        // Echo GET
        res = http.get(`${baseUrl}/echo`, defaultParams);
    } else if (rand < WORKLOAD.health + WORKLOAD.echoGet + WORKLOAD.echoPost) {
        // Echo POST with body
        const body = randomJsonBody(1024); // 1KB body
        res = http.post(`${baseUrl}/echo`, body, {
            ...defaultParams,
            headers: {
                ...defaultParams.headers,
                'Content-Type': 'application/json',
            },
        });
    } else {
        // Large response
        res = http.get(`${baseUrl}/blob`, {
            ...defaultParams,
            responseType: 'binary',
        });
    }

    const success = check(res, {
        'status is 200': (r) => r.status === 200,
    });

    errorRate.add(!success);
}

export function handleSummary(data) {
    const summary = {
        scenario: 'mixed',
        timestamp: new Date().toISOString(),
        server: config.targetHost,
        config: {
            vus: config.vus,
            duration: config.duration,
            workload: WORKLOAD,
        },
        metrics: {
            requests_total: data.metrics.http_reqs.values.count,
            requests_per_second: data.metrics.http_reqs.values.rate,
            errors_total: data.metrics.http_req_failed.values.passes, // passes = requests where failed=true
            error_rate: data.metrics.http_req_failed.values.rate,
            latency_avg_ms: data.metrics.http_req_duration.values.avg,
            latency_p50_ms: data.metrics.http_req_duration.values.med,
            latency_p95_ms: data.metrics.http_req_duration.values['p(95)'],
            latency_p99_ms: data.metrics.http_req_duration.values['p(99)'],
            latency_max_ms: data.metrics.http_req_duration.values.max,
            data_received_mb: (data.metrics.data_received?.values?.count || 0) / 1024 / 1024,
            data_sent_mb: (data.metrics.data_sent?.values?.count || 0) / 1024 / 1024,
        },
    };

    return {
        'stdout': textSummary(data, { indent: ' ', enableColors: true }),
        '/results/mixed.json': JSON.stringify(summary, null, 2),
    };
}
