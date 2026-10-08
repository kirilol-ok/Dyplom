import { Counter, Rate, Trend } from 'k6/metrics';
import { expectedResponse } from './benchmark-common.js';

export const policyAllowedRequests = new Counter('policy_allowed_requests');
export const policyBlockedRequests = new Counter('policy_blocked_requests');
export const policyAllowedExpectedRate = new Rate('policy_allowed_expected_rate');
export const policyBlockedExpectedRate = new Rate('policy_blocked_expected_rate');
export const policyAllowedDurationMs = new Trend('policy_allowed_duration_ms', true);
export const policyBlockedDurationMs = new Trend('policy_blocked_duration_ms', true);
export const policyAllowedConnectingMs = new Trend('policy_allowed_connecting_ms', true);
export const policyBlockedConnectingMs = new Trend('policy_blocked_connecting_ms', true);

export function recordPolicyResult(response, mode, trafficClass) {
  const expected = expectedResponse(response, mode);

  if (trafficClass === 'allowed') {
    policyAllowedRequests.add(1);
    policyAllowedExpectedRate.add(expected);
    policyAllowedDurationMs.add(response.timings.duration);
    policyAllowedConnectingMs.add(response.timings.connecting);
    return;
  }

  policyBlockedRequests.add(1);
  policyBlockedExpectedRate.add(expected);
  policyBlockedDurationMs.add(response.timings.duration);
  policyBlockedConnectingMs.add(response.timings.connecting);
}

export function complexPolicyThresholds() {
  return {
    expected_status_rate: ['rate>0.95'],
    policy_allowed_expected_rate: ['rate>0.95'],
    policy_blocked_expected_rate: ['rate>0.95'],
  };
}
