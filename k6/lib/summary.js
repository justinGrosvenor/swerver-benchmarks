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

// Build handleSummary return object that writes results both to stdout
// (via __RESULT_JSON_START__/__RESULT_JSON_END__ delimiters for reliable
// capture by the runner) and to /results/<slug>.json (volume mount fallback).
//
// Usage in k6 scripts:
//   export function handleSummary(data) {
//     const result = { scenario: 'my-test', ... };
//     return emitResult(data, 'my-test', result);
//   }
export function emitResult(data, slug, result, extraStdout) {
    const text = (extraStdout || '') + textSummary(data);
    const json = JSON.stringify(result, null, 2);
    return {
        stdout: text + '\n__RESULT_JSON_START__\n' + json + '\n__RESULT_JSON_END__\n',
        [`/results/${slug}.json`]: json,
    };
}
