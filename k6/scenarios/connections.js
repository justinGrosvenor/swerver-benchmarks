// Connection handling benchmark
// Goal: Test connection setup/teardown overhead (no keep-alive)

import http from 'k6/http';
import { check } from 'k6';
import { Rate, Counter } from 'k6/metrics';
import { config, baseUrl, noKeepAliveParams, connectionThresholds } from '/lib/helpers.js';
import { textSummary } from '/lib/summary.js';

const errorRate = new Rate('errors');
const connections = new Counter('connections_total');

export const options = {
    vus: config.vus,
    duration: config.duration,
    thresholds: connectionThresholds,
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
    // Disable connection reuse
    noConnectionReuse: true,
};

export default function() {
    const res = http.get(`${baseUrl}/health`, noKeepAliveParams);

    const success = check(res, {
        'status is 200': (r) => r.status === 200,
    });

    errorRate.add(!success);
    connections.add(1);
}

export function handleSummary(data) {
    const summary = {
        scenario: 'connections',
        timestamp: new Date().toISOString(),
        server: config.targetHost,
        config: {
            vus: config.vus,
            duration: config.duration,
            keep_alive: false,
        },
        metrics: {
            connections_total: data.metrics.http_reqs.values.count,
            connections_per_second: data.metrics.http_reqs.values.rate,
            errors_total: data.metrics.http_req_failed.values.passes,
            error_rate: data.metrics.http_req_failed.values.rate,
            latency_avg_ms: data.metrics.http_req_duration.values.avg,
            latency_p95_ms: data.metrics.http_req_duration.values['p(95)'],
            latency_p99_ms: data.metrics.http_req_duration.values['p(99)'],
            latency_max_ms: data.metrics.http_req_duration.values.max,
            // Connection time breakdown
            connect_avg_ms: data.metrics.http_req_connecting?.values?.avg || 0,
            connect_p95_ms: data.metrics.http_req_connecting?.values?.['p(95)'] || 0,
        },
    };

    return {
        'stdout': textSummary(data, { indent: ' ', enableColors: true }),
        '/results/connections.json': JSON.stringify(summary, null, 2),
    };
}
