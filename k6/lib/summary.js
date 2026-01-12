// Lightweight text summary to avoid remote imports in restricted environments.

function formatNumber(value, digits = 2) {
    if (value === undefined || value === null) {
        return 'N/A';
    }
    if (typeof value === 'number') {
        return value.toFixed(digits);
    }
    return String(value);
}

export function textSummary(data, { indent = ' ' } = {}) {
    const metrics = data.metrics || {};
    const duration = metrics.http_req_duration?.values || {};
    const reqs = metrics.http_reqs?.values || {};
    const failed = metrics.http_req_failed?.values || {};

    const lines = [
        'Summary',
        `${indent}requests: ${formatNumber(reqs.count, 0)} total, ${formatNumber(reqs.rate)} req/s`,
        `${indent}latency p95: ${formatNumber(duration['p(95)'])} ms, p99: ${formatNumber(duration['p(99)'])} ms`,
        `${indent}errors: ${formatNumber(failed.rate, 4)} rate`,
    ];

    return lines.join('\n');
}
