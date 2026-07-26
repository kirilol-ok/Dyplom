import { cfg, executeRequest, makeSummary, policyPause, standardThresholds } from './benchmark-common.js';

export const options = {
  scenarios: {
    concurrency: {
      executor: 'constant-vus',
      vus: cfg.vus,
      duration: cfg.duration,
      gracefulStop: '10s',
    },
  },
  noConnectionReuse: cfg.noConnectionReuse,
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds: standardThresholds(false),
  tags: {
    profile: 'concurrency-vus',
    model: cfg.model,
  },
};

export default function () {
  executeRequest(__ITER);
  policyPause();
}

export function handleSummary(data) {
  return makeSummary(data, 'concurrency-vus');
}
