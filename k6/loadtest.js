import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const cfg = {
  model: __ENV.MODEL || 'unknown',
  targetUrl: __ENV.TARGET_URL || 'http://client:8080/proxy',
  vus: Number(__ENV.VUS || 20),
  duration: __ENV.DURATION || '30s',
  rps: Number(__ENV.RPS || 0),
  testMode: __ENV.TEST_MODE || 'allowed',
  requestMethod: (__ENV.REQUEST_METHOD || 'GET').toUpperCase(),
  requestPath: __ENV.REQUEST_PATH || '/api/data',
  payloadSize: Number(__ENV.PAYLOAD_SIZE || 128),
  responseSize: Number(__ENV.RESPONSE_SIZE || 128),
  serverDelayMs: Number(__ENV.SERVER_DELAY_MS || 0),
  timeout: __ENV.TIMEOUT || '5s',
  sleepMs: Number(__ENV.SLEEP_MS || 100),
  noConnectionReuse: (__ENV.NO_CONNECTION_REUSE || 'false') === 'true',
  failRateThreshold: Number(__ENV.FAIL_RATE_THRESHOLD || 0.05),
  p95ThresholdMs: Number(__ENV.P95_THRESHOLD_MS || 1000),
  successRateThreshold: Number(__ENV.SUCCESS_RATE_THRESHOLD || 0.95),
};

export const success_rate = new Rate('success_rate');
export const blocked_expected_rate = new Rate('blocked_expected_rate');
export const upstream_latency_ms = new Trend('upstream_latency_ms');
export const expected_blocked_count = new Counter('expected_blocked_count');

export const options = {
  vus: cfg.vus,
  duration: cfg.duration,
  noConnectionReuse: cfg.noConnectionReuse,
  thresholds: {
    http_req_failed: [`rate<${cfg.failRateThreshold}`],
    http_req_duration: [`p(95)<${cfg.p95ThresholdMs}`],
    success_rate: [`rate>${cfg.successRateThreshold}`],
  },
};

function makePayload(size) {
  if (size <= 0) {
    return '';
  }
  return 'x'.repeat(size);
}

function pickCase() {
  if (cfg.testMode === 'blocked') {
    return { method: 'POST', path: '/api/data', expected: 403 };
  }

  if (cfg.testMode === 'admin-blocked') {
    return { method: 'GET', path: '/admin', expected: 403 };
  }

  if (cfg.testMode === 'mixed') {
    const i = __ITER % 4;
    if (i === 0) return { method: 'GET', path: '/api/data', expected: 200 };
    if (i === 1) return { method: 'GET', path: '/health', expected: 200 };
    if (i === 2) return { method: 'POST', path: '/api/data', expected: 403 };
    return { method: 'GET', path: '/admin', expected: 403 };
  }

  return { method: cfg.requestMethod, path: cfg.requestPath, expected: 200 };
}

function buildProxyUrl(testCase) {
  const query = [
    `path=${encodeURIComponent(testCase.path)}`,
    `method=${encodeURIComponent(testCase.method)}`,
    `payload_size=${cfg.payloadSize}`,
    `response_size=${cfg.responseSize}`,
    `server_delay_ms=${cfg.serverDelayMs}`,
    `timeout_s=${encodeURIComponent(cfg.timeout.replace('s', ''))}`,
  ].join('&');
  return `${cfg.targetUrl}?${query}`;
}

function sleepBetweenRequests() {
  if (cfg.rps > 0) {
    sleep(1 / cfg.rps);
    return;
  }
  if (cfg.sleepMs > 0) {
    sleep(cfg.sleepMs / 1000);
  }
}

export default function () {
  const testCase = pickCase();
  const url = buildProxyUrl(testCase);
  const body = testCase.method === 'GET' || testCase.method === 'DELETE' ? null : makePayload(cfg.payloadSize);
  const params = {
    timeout: cfg.timeout,
    headers: {
      'Content-Type': 'application/octet-stream',
      'X-Test-Mode': cfg.testMode,
    },
    tags: {
      test_mode: cfg.testMode,
      expected_status: String(testCase.expected),
      request_method: testCase.method,
      request_path: testCase.path,
    },
  };

  const response = http.request(testCase.method, url, body, params);
  const upstreamHeader = response.headers['X-Upstream-Latency-Ms'];
  if (upstreamHeader) {
    upstream_latency_ms.add(Number(upstreamHeader));
  }

  const expected = response.status === testCase.expected;
  success_rate.add(expected);

  if (testCase.expected === 403) {
    expected_blocked_count.add(1);
    blocked_expected_rate.add(response.status === 403);
  } else {
    blocked_expected_rate.add(true);
  }

  check(response, {
    'status is expected': () => expected,
    'response has body': (r) => r.body && r.body.length > 0,
  });

  sleepBetweenRequests();
}

function metricLine(data, metricName, key, label) {
  let value = undefined;
  if (data.metrics && data.metrics[metricName] && data.metrics[metricName].values) {
    value = data.metrics[metricName].values[key];
  }
  if (value === undefined) {
    return `${label}: -`;
  }
  if (key === 'rate') {
    return `${label}: ${(value * 100).toFixed(2)}%`;
  }
  return `${label}: ${Number(value).toFixed(2)}`;
}

export function handleSummary(data) {
  data.diploma = cfg;
  const text = [
    '',
    'Diploma k6 summary',
    `model: ${cfg.model}`,
    `mode: ${cfg.testMode}`,
    `target: ${cfg.targetUrl}`,
    `vus: ${cfg.vus}`,
    `duration: ${cfg.duration}`,
    metricLine(data, 'http_reqs', 'rate', 'http req/s'),
    metricLine(data, 'http_req_duration', 'avg', 'http avg ms'),
    metricLine(data, 'http_req_duration', 'p(95)', 'http p95 ms'),
    metricLine(data, 'http_req_failed', 'rate', 'http fail rate'),
    metricLine(data, 'success_rate', 'rate', 'expected success rate'),
    '',
  ].join('\n');

  return {
    stdout: text,
    '/results/summary.json': JSON.stringify(data, null, 2),
  };
}
