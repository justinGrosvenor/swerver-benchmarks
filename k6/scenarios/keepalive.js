// Keepalive efficiency benchmark
// Goal: Measure throughput and latency gain from HTTP keepalive vs Connection: close

import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { config, baseUrl, defaultParams, noKeepAliveParams } from '/lib/helpers.js';
import { textSummary } from '/lib/summary.js';

// Per-mode custom metrics
const keepaliveLatency = new Trend('keepalive_latency', true);
const noKeepaliveLatency = new Trend('no_keepalive_latency', true);
const keepaliveReqs = new Counter('keepalive_requests');
const noKeepaliveReqs = new Counter('no_keepalive_requests');

export const options = {
    scenarios: {
        keepalive: {
            executor: 'constant-vus',
            vus: 50,
            duration: '30s',
            exec: 'withKeepalive',
        },
        no_keepalive: {
            executor: 'constant-vus',
            vus: 50,
            duration: '30s',
            exec: 'withoutKeepalive',
            tags: { mode: 'no_keepalive' },
        },
    },
    thresholds: {
        http_req_duration: ['p(95)<300'],
        http_req_failed: ['rate<0.05'],
    },
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

export function withKeepalive() {
    const res = http.get(`${baseUrl}/health`, defaultParams);
    check(res, { 'status is 200': (r) => r.status === 200 });
    keepaliveLatency.add(res.timings.duration);
    keepaliveReqs.add(1);
}

export function withoutKeepalive() {
    const res = http.get(`${baseUrl}/health`, noKeepAliveParams);
    check(res, { 'status is 200': (r) => r.status === 200 });
    noKeepaliveLatency.add(res.timings.duration);
    noKeepaliveReqs.add(1);
}

export function handleSummary(data) {
    const duration = 30; // seconds
    const kaReqs = data.metrics.keepalive_requests?.values?.count || 0;
    const noKaReqs = data.metrics.no_keepalive_requests?.values?.count || 0;
    const kaRps = kaReqs / duration;
    const noKaRps = noKaReqs / duration;
    const efficiencyPct = noKaRps > 0 ? ((kaRps - noKaRps) / noKaRps * 100) : null;

    const summary = {
        scenario: 'keepalive',
        timestamp: new Date().toISOString(),
        server: config.targetHost,
        config: {
            vus_per_mode: 50,
            duration: '30s',
        },
        metrics: {
            requests_total: data.metrics.http_reqs.values.count,
            requests_per_second: data.metrics.http_reqs.values.rate,
            error_rate: data.metrics.http_req_failed.values.rate,
            latency_p95_ms: data.metrics.http_req_duration.values['p(95)'],
            latency_p99_ms: data.metrics.http_req_duration.values['p(99)'],
            // Per-mode metrics
            keepalive_rps: kaRps,
            keepalive_latency_avg_ms: data.metrics.keepalive_latency?.values?.avg || null,
            keepalive_latency_p95_ms: data.metrics.keepalive_latency?.values?.['p(95)'] || null,
            no_keepalive_rps: noKaRps,
            no_keepalive_latency_avg_ms: data.metrics.no_keepalive_latency?.values?.avg || null,
            no_keepalive_latency_p95_ms: data.metrics.no_keepalive_latency?.values?.['p(95)'] || null,
            keepalive_efficiency_pct: efficiencyPct,
        },
    };

    return {
        'stdout': textSummary(data, { indent: ' ', enableColors: true }),
        [`/results/${config.targetHost}_keepalive.json`]: JSON.stringify(summary, null, 2),
    };
}
