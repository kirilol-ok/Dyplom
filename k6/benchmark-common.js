import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

export const cfg = {
  model: __ENV.MODEL || 'unknown',
  targetUrl: __ENV.TARGET_URL || 'http://client:8080/proxy',
  targetMode: (__ENV.TARGET_MODE || 'proxy').toLowerCase(),
  vus: Math.max(1, Number(__ENV.VUS || 20)),
  duration: __ENV.DURATION || '30s',
  rps: Math.max(0, Number(__ENV.RPS || 0)),
  testMode: __ENV.TEST_MODE || 'allowed',
  requestMethod: (__ENV.REQUEST_METHOD || 'GET').toUpperCase(),
  requestPath: __ENV.REQUEST_PATH || '/api/data',
  payloadSize: Math.max(0, Number(__ENV.PAYLOAD_SIZE || 128)),
  responseSize: Math.max(0, Number(__ENV.RESPONSE_SIZE || 128)),
  serverDelayMs: Math.max(0, Number(__ENV.SERVER_DELAY_MS || 0)),
  timeout: __ENV.TIMEOUT || '5s',
  sleepMs: Math.max(0, Number(__ENV.SLEEP_MS || 100)),
  noConnectionReuse: (__ENV.NO_CONNECTION_REUSE || 'false') === 'true',
  failRateThreshold: Number(__ENV.FAIL_RATE_THRESHOLD || 0.05),
  p95ThresholdMs: Number(__ENV.P95_THRESHOLD_MS || 1000),
  successRateThreshold: Number(__ENV.SUCCESS_RATE_THRESHOLD || 0.95),
};

export const expected_status_rate = new Rate('expected_status_rate');
// Kept for compatibility with the previous shell scripts.
export const success_rate = new Rate('success_rate');
export const allowed_success_rate = new Rate('allowed_success_rate');
export const blocked_success_rate = new Rate('blocked_success_rate');
export const expected_blocked_count = new Counter('expected_blocked_count');
export const upstream_latency_ms = new Trend('upstream_latency_ms');
export const infrastructure_overhead_ms = new Trend('infrastructure_overhead_ms');
export const response_body_bytes = new Trend('response_body_bytes');

const expected200 = http.expectedStatuses(200);
const expected403 = http.expectedStatuses(403);

function isL7Model() {
  const model = cfg.model.toLowerCase();
  return model.includes('l7') || model.includes('dikastes');
}

function l7ExpectedStatus() {
  return isL7Model() ? 403 : 200;
}

export function makePayload(size) {
  return size > 0 ? 'x'.repeat(size) : '';
}

export function pickCase(iteration) {
  if (cfg.testMode === 'blocked') {
    return {
      name: 'method-policy',
      method: 'POST',
      path: '/api/data',
      expected: l7ExpectedStatus(),
    };
  }

  if (cfg.testMode === 'admin-blocked') {
    return {
      name: 'path-policy',
      method: 'GET',
      path: '/admin',
      expected: l7ExpectedStatus(),
    };
  }

  if (cfg.testMode === 'mixed') {
    const cases = [
      { name: 'api-allowed', method: 'GET', path: '/api/data', expected: 200 },
      { name: 'health-allowed', method: 'GET', path: '/health', expected: 200 },
      { name: 'method-policy', method: 'POST', path: '/api/data', expected: l7ExpectedStatus() },
      { name: 'path-policy', method: 'GET', path: '/admin', expected: l7ExpectedStatus() },
    ];
    return cases[iteration % cases.length];
  }

  return {
    name: 'custom-allowed',
    method: cfg.requestMethod,
    path: cfg.requestPath,
    expected: 200,
  };
}

function timeoutSeconds() {
  const parsed = Number(String(cfg.timeout).replace(/s$/i, ''));
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 5;
}

export function buildProxyUrl(testCase) {
  const query = [
    `path=${encodeURIComponent(testCase.path)}`,
    `method=${encodeURIComponent(testCase.method)}`,
    `payload_size=${cfg.payloadSize}`,
    `response_size=${cfg.responseSize}`,
    `server_delay_ms=${cfg.serverDelayMs}`,
    `timeout_s=${timeoutSeconds()}`,
  ].join('&');

  return `${cfg.targetUrl}?${query}`;
}

function removeTrailingSlash(value) {
  return value.endsWith('/') ? value.slice(0, -1) : value;
}

export function buildDirectUrl(testCase) {
  const baseUrl = removeTrailingSlash(cfg.targetUrl);

  const query = [
    `response_size=${cfg.responseSize}`,
    `server_delay_ms=${cfg.serverDelayMs}`,
  ].join('&');

  return `${baseUrl}${testCase.path}?${query}`;
}

export function buildRequestUrl(testCase) {
  if (cfg.targetMode === 'direct') {
    return buildDirectUrl(testCase);
  }

  return buildProxyUrl(testCase);
}

export function executeRequest(iteration) {
  const testCase = pickCase(iteration);
  const url = buildRequestUrl(testCase);
  const hasBody = !['GET', 'DELETE', 'HEAD'].includes(testCase.method);
  const body = hasBody ? makePayload(cfg.payloadSize) : null;
  const tags = {
    model: cfg.model,
    target_mode: cfg.targetMode,
    test_mode: cfg.testMode,
    case_name: testCase.name,
    expected_status: String(testCase.expected),
    request_method: testCase.method,
    request_path: testCase.path,
  };

  const params = {
    timeout: cfg.timeout,
    responseCallback: testCase.expected === 403 ? expected403 : expected200,
    headers: {
      'Content-Type': 'application/octet-stream',
      'X-Test-Mode': cfg.testMode,
    },
    tags,
  };

  const response = http.request(testCase.method, url, body, params);
  const expected = response.status === testCase.expected;

  expected_status_rate.add(expected, tags);
  success_rate.add(expected, tags);

  if (testCase.expected === 403) {
    expected_blocked_count.add(1, tags);
    blocked_success_rate.add(response.status === 403, tags);
  } else {
    allowed_success_rate.add(response.status === 200, tags);
  }

  const upstreamHeader =
    response.headers['X-Upstream-Latency-Ms'] ||
    response.headers['x-upstream-latency-ms'];

  if (upstreamHeader !== undefined) {
    const upstream = Number(upstreamHeader);
    if (Number.isFinite(upstream)) {
      upstream_latency_ms.add(upstream, tags);
      infrastructure_overhead_ms.add(
        Math.max(0, response.timings.duration - upstream),
        tags,
      );
    }
  }

  if (response.body !== null && response.body !== undefined) {
    response_body_bytes.add(String(response.body).length, tags);
  }

  check(
    response,
    {
      'status is expected': () => expected,
      'allowed response has body': (r) =>
        testCase.expected === 403 ||
        (r.body !== null && r.body !== undefined && String(r.body).length > 0),
    },
    tags,
  );

  return response;
}

export function policyPause() {
  if (cfg.sleepMs > 0) {
    sleep(cfg.sleepMs / 1000);
  }
}

export function standardThresholds(includeDroppedIterations = true) {
  const thresholds = {
    http_req_failed: [`rate<${cfg.failRateThreshold}`],
    http_req_duration: [`p(95)<${cfg.p95ThresholdMs}`],
    expected_status_rate: [`rate>=${cfg.successRateThreshold}`],
    checks: [`rate>=${cfg.successRateThreshold}`],
  };

  if (includeDroppedIterations) {
    thresholds.dropped_iterations = ['count==0'];
  }

  return thresholds;
}

export function strictPolicyThresholds() {
  return {
    http_req_failed: ['rate==0'],
    expected_status_rate: ['rate==1'],
    checks: ['rate==1'],
  };
}

function metricValue(data, metricName, key) {
  const metric = data.metrics && data.metrics[metricName];
  if (!metric || !metric.values) {
    return undefined;
  }
  return metric.values[key];
}

function formatMetric(data, metricName, key, label, percent = false) {
  const value = metricValue(data, metricName, key);
  if (value === undefined) {
    return `${label}: -`;
  }

  if (percent) {
    return `${label}: ${(Number(value) * 100).toFixed(2)}%`;
  }

  return `${label}: ${Number(value).toFixed(2)}`;
}

export function makeSummary(data, profile) {
  const diploma = {};

  Object.keys(cfg).forEach(function (key) {
    diploma[key] = cfg[key];
  });

  diploma.profile = profile;
  data.diploma = diploma;

  const lines = [
    '',
    'Diploma k6 benchmark summary',
    `profile: ${profile}`,
    `model: ${cfg.model}`,
    `mode: ${cfg.testMode}`,
    `target: ${cfg.targetUrl}`,
    `target mode: ${cfg.targetMode}`,
    `configured rps: ${cfg.rps || '-'}`,
    `preallocated VUs: ${cfg.vus}`,
    `duration: ${cfg.duration}`,
    `connection reuse disabled: ${cfg.noConnectionReuse}`,
    formatMetric(data, 'http_reqs', 'rate', 'achieved req/s'),
    formatMetric(data, 'http_req_duration', 'avg', 'http avg ms'),
    formatMetric(data, 'http_req_duration', 'p(95)', 'http p95 ms'),
    formatMetric(data, 'http_req_duration', 'p(99)', 'http p99 ms'),
    formatMetric(data, 'http_req_failed', 'rate', 'http fail rate', true),
    formatMetric(data, 'expected_status_rate', 'rate', 'expected status rate', true),
    formatMetric(data, 'dropped_iterations', 'count', 'dropped iterations'),
    formatMetric(data, 'upstream_latency_ms', 'avg', 'upstream avg ms'),
    formatMetric(data, 'upstream_latency_ms', 'p(95)', 'upstream p95 ms'),
    formatMetric(data, 'infrastructure_overhead_ms', 'avg', 'overhead avg ms'),
    formatMetric(data, 'infrastructure_overhead_ms', 'p(95)', 'overhead p95 ms'),
    '',
  ];

  return {
    stdout: lines.join('\n'),
    '/results/summary.json': JSON.stringify(data, null, 2),
  };
}
