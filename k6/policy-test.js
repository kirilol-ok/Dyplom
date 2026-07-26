import { cfg, executeRequest, makeSummary, policyPause, strictPolicyThresholds } from './benchmark-common.js';

export const options = {
  scenarios: {
    policy: {
      executor: 'constant-vus',
      vus: cfg.vus,
      duration: cfg.duration,
      gracefulStop: '5s',
    },
  },
  noConnectionReuse: cfg.noConnectionReuse,
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds: strictPolicyThresholds(),
  tags: {
    profile: 'policy',
    model: cfg.model,
  },
};

export default function () {
  executeRequest(__ITER);
  policyPause();
}

export function handleSummary(data) {
  return makeSummary(data, 'policy');
}
