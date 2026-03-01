// Soak/stability benchmark
// Goal: Detect memory leaks, resource exhaustion, or degradation over time
// NOTE: Excluded from default SCENARIOS — opt-in via SCENARIOS="... soak"

import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';
import { config, baseUrl, defaultParams, randomJsonBody, soakThresholds } from '/lib/helpers.js';
import { textSummary } from '/lib/summary.js';

const errorRate = new Rate('errors');

export const options = {
    stages: [
        { duration: '15s', target: 50 },     // Ramp up
        { duration: '270s', target: 50 },    // Sustained load
        { duration: '15s', target: 0 },      // Ramp down
    ],
    thresholds: soakThresholds,
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)', 'p(99.9)'],
};

// Same workload mix as mixed.js
const WORKLOAD = {
    health: 0.30,
    echoGet: 0.40,
    echoPost: 0.20,
    blob: 0.10,
};

export default function() {
    const rand = Math.random();
    let res;

    if (rand < WORKLOAD.health) {
        res = http.get(`${baseUrl}/health`, defaultParams);
    } else if (rand < WORKLOAD.health + WORKLOAD.echoGet) {
        res = http.get(`${baseUrl}/echo`, defaultParams);
    } else if (rand < WORKLOAD.health + WORKLOAD.echoGet + WORKLOAD.echoPost) {
        const body = randomJsonBody(1024);
        res = http.post(`${baseUrl}/echo`, body, {
            ...defaultParams,
            headers: {
                ...defaultParams.headers,
                'Content-Type': 'application/json',
            },
        });
    } else {
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
        scenario: 'soak',
        timestamp: new Date().toISOString(),
        server: config.targetHost,
        config: {
            vus: 50,
            total_duration: '300s',
            workload: WORKLOAD,
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
            latency_p999_ms: data.metrics.http_req_duration.values['p(99.9)'],
            latency_max_ms: data.metrics.http_req_duration.values.max,
        },
    };

    return {
        'stdout': textSummary(data, { indent: ' ', enableColors: true }),
        [`/results/${config.targetHost}_soak.json`]: JSON.stringify(summary, null, 2),
    };
}
