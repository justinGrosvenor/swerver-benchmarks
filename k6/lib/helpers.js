// Shared utilities for k6 benchmark scenarios

// Environment configuration with defaults
export const config = {
    targetHost: __ENV.TARGET_HOST || 'localhost',
    targetPort: __ENV.TARGET_PORT || '8080',
    vus: parseInt(__ENV.K6_VUS) || 100,
    duration: __ENV.K6_DURATION || '30s',
};

// Base URL for all requests
export const baseUrl = `http://${config.targetHost}:${config.targetPort}`;

// Standard request parameters
export const defaultParams = {
    headers: {
        'Accept': 'application/json',
    },
    timeout: '10s',
};

// Parameters for connection-close testing
export const noKeepAliveParams = {
    ...defaultParams,
    headers: {
        ...defaultParams.headers,
        'Connection': 'close',
    },
};

// Check response helper
export function checkResponse(res, checks) {
    let passed = true;
    for (const [name, fn] of Object.entries(checks)) {
        if (!fn(res)) {
            console.error(`Check failed: ${name}`);
            passed = false;
        }
    }
    return passed;
}

// Generate random JSON body of specified size (approximate)
export function randomJsonBody(sizeBytes) {
    const overhead = 20; // {"data":"..."}
    const dataLen = Math.max(0, sizeBytes - overhead);
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    let data = '';
    for (let i = 0; i < dataLen; i++) {
        data += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return JSON.stringify({ data });
}

// Standard thresholds for benchmarks
export const standardThresholds = {
    http_req_duration: ['p(95)<100', 'p(99)<200'],
    http_req_failed: ['rate<0.01'],
    http_reqs: ['rate>1000'],
};

// Relaxed thresholds for connection-heavy tests
export const connectionThresholds = {
    http_req_duration: ['p(95)<200', 'p(99)<500'],
    http_req_failed: ['rate<0.05'],
    http_reqs: ['rate>500'],
};

// Format results for JSON output
export function formatResults(data) {
    return {
        timestamp: new Date().toISOString(),
        server: config.targetHost,
        config: {
            vus: config.vus,
            duration: config.duration,
        },
        metrics: data,
    };
}
