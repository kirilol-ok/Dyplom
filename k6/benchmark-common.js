import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

export const expectedStatusRate = new Rate('expected_status_rate');
export const appProcessingMs = new Trend('app_processing_ms', true);
export const infrastructureOverheadMs = new Trend('infrastructure_overhead_ms', true);

export function env(name, fallback) {
  const value = __ENV[name];
  return value === undefined || value === '' ? fallback : value;
}

export function toInt(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export function toFloat(value, fallback) {
  const parsed = Number.parseFloat(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export function toBool(value, fallback = false) {
  if (value === undefined || value === '') return fallback;
  return String(value).toLowerCase() === 'true';
}

export const cfg = {
  model: env('MODEL', 'unknown'),
  targetUrl: env('TARGET_URL', 'http://server:8080'),
  targetMode: env('TARGET_MODE', 'direct'),
  vus: toInt(env('VUS', '100'), 100),
  duration: env('DURATION', '45s'),
  rps: toInt(env('RPS', '0'), 0),
  payloadSize: toInt(env('PAYLOAD_SIZE', '128'), 128),
  responseSize: toInt(env('RESPONSE_SIZE', '128'), 128),
  requestMethod: env('REQUEST_METHOD', 'GET').toUpperCase(),
  requestPath: env('REQUEST_PATH', '/api/data'),
  testMode: env('TEST_MODE', 'allowed'),
  noConnectionReuse: toBool(env('NO_CONNECTION_REUSE', 'false')),
  serverDelayMs: toInt(env('SERVER_DELAY_MS', '0'), 0),
  timeout: env('TIMEOUT', '5s'),
  sleepMs: toInt(env('SLEEP_MS', '0'), 0),
  allowedRps: toInt(env('ALLOWED_RPS', '0'), 0),
  blockedRps: toInt(env('BLOCKED_RPS', '0'), 0),
  blockedTargetUrl: env('BLOCKED_TARGET_URL', 'http://server:8081'),
  blockedMethod: env('BLOCKED_METHOD', 'GET').toUpperCase(),
  blockedPath: env('BLOCKED_PATH', '/health'),
  scenarioVariant: env('SCENARIO_VARIANT', 'default'),
};

function makePayload(size) {
  if (size <= 0) return null;
  return 'x'.repeat(size);
}

function joinTarget(target, path) {
  if (!path) return target;
  if (target.endsWith('/') && path.startsWith('/')) return target.slice(0, -1) + path;
  if (!target.endsWith('/') && !path.startsWith('/')) return `${target}/${path}`;
  return target + path;
}

function requestUrl(targetUrl, requestPath) {
  const base = joinTarget(targetUrl, requestPath);
  const separator = base.includes('?') ? '&' : '?';
  return `${base}${separator}response_size=${cfg.responseSize}&server_delay_ms=${cfg.serverDelayMs}`;
}

export function expectedResponse(res, mode) {
  switch (mode) {
    case 'allowed':
    case 'baseline-open':
      return res.status === 200;
    case 'l4-blocked':
      return res.status === 0 || res.status === 403;
    case 'l7-blocked':
      return res.status === 403;
    default:
      return res.status === 200;
  }
}

export function executeRequest(iteration, overrides = {}) {
  const method = (overrides.method || cfg.requestMethod).toUpperCase();
  const path = overrides.path === undefined ? cfg.requestPath : overrides.path;
  const targetUrl = overrides.targetUrl || cfg.targetUrl;
  const mode = overrides.testMode || cfg.testMode;
  const url = requestUrl(targetUrl, path);
  const body = method === 'GET' || method === 'HEAD' ? null : makePayload(cfg.payloadSize);

  const response = http.request(method, url, body, {
    timeout: cfg.timeout,
    tags: {
      model: cfg.model,
      test_mode: mode,
      request_path: path,
    },
  });

  const expected = expectedResponse(response, mode);
  expectedStatusRate.add(expected);
  check(response, {
    'response matches expected policy result': () => expected,
  });

  const appHeader = response.headers['X-App-Processing-Ms'];
  const appMs = toFloat(appHeader, NaN);
  if (Number.isFinite(appMs)) {
    appProcessingMs.add(appMs);
    infrastructureOverheadMs.add(Math.max(0, response.timings.duration - appMs));
  }

  return response;
}

export function performanceThresholds() {
  return {
    expected_status_rate: ['rate>0.95'],
  };
}

export function verificationThresholds() {
  return {
    expected_status_rate: ['rate>0.99'],
    checks: ['rate>0.99'],
  };
}

function metricValue(data, metric, key, fallback = 0) {
  return data.metrics?.[metric]?.values?.[key] ?? fallback;
}

function percentage(value) {
  return `${(Number(value || 0) * 100).toFixed(2)}%`;
}

export function makeSummary(data, profile) {
  data.diploma = {
    profile,
    model: cfg.model,
    targetUrl: cfg.targetUrl,
    targetMode: cfg.targetMode,
    vus: cfg.vus,
    duration: cfg.duration,
    rps: cfg.rps,
    payloadSize: cfg.payloadSize,
    responseSize: cfg.responseSize,
    requestMethod: cfg.requestMethod,
    requestPath: cfg.requestPath,
    testMode: cfg.testMode,
    noConnectionReuse: cfg.noConnectionReuse,
    serverDelayMs: cfg.serverDelayMs,
    allowedRps: cfg.allowedRps,
    blockedRps: cfg.blockedRps,
    blockedTargetUrl: cfg.blockedTargetUrl,
    blockedMethod: cfg.blockedMethod,
    blockedPath: cfg.blockedPath,
    scenarioVariant: cfg.scenarioVariant,
  };

  const duration = data.metrics?.http_req_duration?.values || {};
  const reqRate = metricValue(data, 'http_reqs', 'rate');
  const reqs = metricValue(data, 'http_reqs', 'count');
  const dropped = metricValue(data, 'dropped_iterations', 'count');
  const expected = metricValue(data, 'expected_status_rate', 'rate', 1);
  const failed = metricValue(data, 'http_req_failed', 'rate');

  const text = [
    '',
    'Diploma k6 benchmark summary',
    `profile: ${profile}`,
    `model: ${cfg.model}`,
    `mode: ${cfg.testMode}`,
    `variant: ${cfg.scenarioVariant}`,
    `target: ${cfg.targetUrl}${cfg.requestPath}`,
    `configured rps: ${cfg.rps}`,
    `allowed/blocked rps: ${cfg.allowedRps}/${cfg.blockedRps}`,
    `duration: ${cfg.duration}`,
    `connection reuse disabled: ${cfg.noConnectionReuse}`,
    `requests: ${reqs}`,
    `achieved req/s: ${Number(reqRate).toFixed(2)}`,
    `http p5 ms: ${Number(duration['p(5)'] || 0).toFixed(2)}`,
    `http median ms: ${Number(duration.med || 0).toFixed(2)}`,
    `http p95 ms: ${Number(duration['p(95)'] || 0).toFixed(2)}`,
    `http p99 ms: ${Number(duration['p(99)'] || 0).toFixed(2)}`,
    `http fail rate: ${percentage(failed)}`,
    `expected status rate: ${percentage(expected)}`,
    `dropped iterations: ${dropped}`,
    '',
  ].join('\n');

  return {
    stdout: text,
    '/results/summary.json': JSON.stringify(data, null, 2),
  };
}
