import {
  cfg,
  executeRequest,
  makeSummary,
} from './benchmark-common.js';
import {
  complexPolicyThresholds,
  recordPolicyResult,
} from './complex-policy-metrics.js';

const allowedRate = Math.max(cfg.allowedRps, 1);
const blockedRate = Math.max(cfg.blockedRps, 1);
const totalRate = allowedRate + blockedRate;
const totalVUs = Math.max(cfg.vus, 2);
const allowedVUs = Math.max(1, Math.round(totalVUs * allowedRate / totalRate));
const blockedVUs = Math.max(1, totalVUs - allowedVUs);
const allowedMaxVUs = Math.max(allowedVUs * 5, allowedRate * 3);
const blockedMaxVUs = Math.max(blockedVUs * 5, blockedRate * 3);

export const options = {
  scenarios: {
    allowed_connections: {
      executor: 'constant-arrival-rate',
      exec: 'allowedConnections',
      rate: allowedRate,
      timeUnit: '1s',
      duration: cfg.duration,
      preAllocatedVUs: allowedVUs,
      maxVUs: allowedMaxVUs,
      gracefulStop: '10s',
      tags: { traffic_class: 'allowed' },
    },
    blocked_connections: {
      executor: 'constant-arrival-rate',
      exec: 'blockedConnections',
      rate: blockedRate,
      timeUnit: '1s',
      duration: cfg.duration,
      preAllocatedVUs: blockedVUs,
      maxVUs: blockedMaxVUs,
      gracefulStop: '10s',
      tags: { traffic_class: 'blocked' },
    },
  },
  noConnectionReuse: true,
  noVUConnectionReuse: true,
  summaryTrendStats: ['avg', 'p(5)', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds: complexPolicyThresholds(),
  tags: {
    profile: 'l4-attack',
    model: cfg.model,
    scenario_variant: cfg.scenarioVariant,
  },
};

export function allowedConnections() {
  const response = executeRequest(__ITER, {
    targetUrl: cfg.targetUrl,
    method: cfg.requestMethod,
    path: cfg.requestPath,
    testMode: 'allowed',
  });
  recordPolicyResult(response, 'allowed', 'allowed');
}

export function blockedConnections() {
  const response = executeRequest(__ITER, {
    targetUrl: cfg.blockedTargetUrl,
    method: cfg.blockedMethod,
    path: cfg.blockedPath,
    testMode: 'l4-blocked',
  });
  recordPolicyResult(response, 'l4-blocked', 'blocked');
}

export function handleSummary(data) {
  return makeSummary(data, 'l4-attack');
}
