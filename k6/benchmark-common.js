import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const expected200 = http.expectedStatuses(200);
const expected403 = http.expectedStatuses(403);

function envNumber(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || raw === '') return fallback;
  const value = Number(raw);
  return Number.isFinite(value) ? value : fallback;
}

function envBool(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || raw === '') return fallback;
  return String(raw).toLowerCase() === 'true';
}

export const cfg = {
  model: __ENV.MODEL || 'baseline',
  targetUrl: __ENV.TARGET_URL || 'http://server:8080',
  vus: Math.max(1, Math.trunc(envNumber('VUS', 50))),
  maxVUs: Math.max(1, Math.trunc(envNumber('MAX_VUS', 1000))),
  duration: __ENV.DURATION || '45s',
  rps: Math.max(0, envNumber('RPS', 0)),
  testMode: __ENV.TEST_MODE || 'allowed',
  requestMethod: (__ENV.REQUEST_METHOD || 'GET').toUpperCase(),
  requestPath: __ENV.REQUEST_PATH || '/api/data',
  payloadSize: Math.max(0, Math.trunc(envNumber('PAYLOAD_SIZE', 0))),
  responseSize: Math.max(0, Math.trunc(envNumber('RESPONSE_SIZE', 128))),
  serverDelayMs: Math.max(0, Math.trunc(envNumber('SERVER_DELAY_MS', 0))),
  timeout: __ENV.REQUEST_TIMEOUT || '5s',
  sleepMs: Math.max(0, envNumber('SLEEP_MS', 0)),
  noConnectionReuse: envBool('NO_CONNECTION_REUSE', false),
  failRateThreshold: envNumber('FAIL_RATE_THRESHOLD', 0.01),
  successRateThreshold: envNumber('SUCCESS_RATE_THRESHOLD', 0.99),
  p95ThresholdMs: envNumber('P95_THRESHOLD_MS', 1000),
};

if (cfg.maxVUs < cfg.vus) {
  cfg.maxVUs = cfg.vus;
}

export const expected_status_rate = new Rate('expected_status_rate');
export const app_processing_ms = new Trend('app_processing_ms', true);
export const infrastructure_overhead_ms = new Trend('infrastructure_overhead_ms', true);

function l7ExpectedStatus() {
  return cfg.model === 'l7-dikastes' ? 403 : 200;
}

function makePayload(size) {
  if (size <= 0) return null;
  return 'x'.repeat(size);
}

export function pickCase(iteration) {
  if (cfg.testMode === 'allowed') {
    return { name: 'api-allowed', method: 'GET', path: '/api/data', expected: 200 };
  }

  if (cfg.testMode === 'blocked') {
    return { name: 'method-policy', method: 'POST', path: '/api/data', expected: l7ExpectedStatus() };
  }

  if (cfg.testMode === 'admin-blocked') {
    return { name: 'path-policy', method: 'GET', path: '/admin', expected: l7ExpectedStatus() };
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

  return { name: 'custom', method: cfg.requestMethod, path: cfg.requestPath, expected: 200 };
}

function removeTrailingSlash(value) {
  return value.endsWith('/') ? value.slice(0, -1) : value;
}

export function buildUrl(testCase) {
  const base = removeTrailingSlash(cfg.targetUrl);
  const query = `response_size=${cfg.responseSize}&server_delay_ms=${cfg.serverDelayMs}`;
  return `${base}${testCase.path}?${query}`;
}

export function executeRequest(iteration) {
  const testCase = pickCase(iteration);
  const tags = {
    model: cfg.model,
    test_mode: cfg.testMode,
    case_name: testCase.name,
    expected_status: String(testCase.expected),
    request_method: testCase.method,
    request_path: testCase.path,
  };

  const hasBody = !['GET', 'DELETE', 'HEAD'].includes(testCase.method);
  const body = hasBody ? makePayload(cfg.payloadSize) : null;
  const params = {
    timeout: cfg.timeout,
    responseCallback: testCase.expected === 403 ? expected403 : expected200,
    headers: { 'Content-Type': 'application/octet-stream' },
    tags,
  };

  const response = http.request(testCase.method, buildUrl(testCase), body, params);
  const expected = response.status === testCase.expected;
  expected_status_rate.add(expected, tags);


  const processingHeader =
    response.headers['X-App-Processing-Ms'] || response.headers['x-app-processing-ms'];
  if (processingHeader !== undefined) {
    const processing = Number(processingHeader);
    if (Number.isFinite(processing)) {
      app_processing_ms.add(processing, tags);
      infrastructure_overhead_ms.add(Math.max(0, response.timings.duration - processing), tags);
    }
  }

  check(response, { 'status is expected': () => expected }, tags);
  return response;
}

export function policyPause() {
  if (cfg.sleepMs > 0) sleep(cfg.sleepMs / 1000);
}

export function standardThresholds(includeDroppedIterations = true) {
  const thresholds = {
    http_req_failed: [`rate<${cfg.failRateThreshold}`],
    http_req_duration: [`p(95)<${cfg.p95ThresholdMs}`],
    expected_status_rate: [`rate>=${cfg.successRateThreshold}`],
    checks: [`rate>=${cfg.successRateThreshold}`],
  };
  if (includeDroppedIterations) thresholds.dropped_iterations = ['count==0'];
  return thresholds;
}

export function strictPolicyThresholds() {
  return {
    http_req_failed: ['rate==0'],
    expected_status_rate: ['rate==1'],
    checks: ['rate==1'],
  };
}

function metric(data, name, key) {
  return data.metrics?.[name]?.values?.[key];
}

function fmt(value, digits = 2) {
  return value === undefined ? '-' : Number(value).toFixed(digits);
}

export function makeSummary(data, profile) {
  data.diploma = { ...cfg, profile };

  const reqs = metric(data, 'http_reqs', 'count') || 0;
  const dropped = metric(data, 'dropped_iterations', 'count') || 0;
  const scheduled = reqs + dropped;
  const delivery = scheduled > 0 ? (100 * reqs) / scheduled : 100;
  const successRate = metric(data, 'expected_status_rate', 'rate');
  const successfulTarget = successRate === undefined ? undefined : delivery * Number(successRate);

  const lines = [
    '',
    `profile=${profile} model=${cfg.model}`,
    `requests=${reqs} dropped=${dropped} target_delivery=${fmt(delivery)}%`,
    `expected_status=${successRate === undefined ? '-' : fmt(successRate * 100)}% successful_target=${fmt(successfulTarget)}%`,
    `latency_ms avg=${fmt(metric(data, 'http_req_duration', 'avg'))} p95=${fmt(metric(data, 'http_req_duration', 'p(95)'))} p99=${fmt(metric(data, 'http_req_duration', 'p(99)'))} max=${fmt(metric(data, 'http_req_duration', 'max'))}`,
    `app_ms p95=${fmt(metric(data, 'app_processing_ms', 'p(95)'))} infrastructure_ms p95=${fmt(metric(data, 'infrastructure_overhead_ms', 'p(95)'))}`,
    '',
  ].join('\n');

  return {
    stdout: lines,
    '/results/summary.json': JSON.stringify(data, null, 2),
  };
}
