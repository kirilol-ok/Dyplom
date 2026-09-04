import { sleep } from 'k6';
import { cfg, executeRequest, makeSummary, verificationThresholds } from './benchmark-common.js';

export const options = {
  scenarios: {
    policy_verification: {
      executor: 'constant-vus',
      vus: 1,
      duration: cfg.duration,
      gracefulStop: '2s',
    },
  },
  noConnectionReuse: cfg.noConnectionReuse,
  summaryTrendStats: ['avg', 'p(5)', 'med', 'p(95)', 'p(99)', 'max'],
  thresholds: verificationThresholds(),
  tags: {
    profile: 'policy-verify',
    model: cfg.model,
  },
};

export default function () {
  executeRequest(__ITER);
  sleep(0.2);
}

export function handleSummary(data) {
  return makeSummary(data, 'policy-verify');
}
