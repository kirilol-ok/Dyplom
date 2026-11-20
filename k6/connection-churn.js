import { cfg, executeRequest, makeSummary, performanceThresholds } from './benchmark-common.js';

const targetRate = cfg.rps > 0 ? cfg.rps : 200;
const maxVUs = cfg.vus;

export const options = {
  scenarios: {
    connection_churn: {
      executor: 'constant-arrival-rate',
      rate: targetRate,
      timeUnit: '1s',
      duration: cfg.duration,
      preAllocatedVUs: cfg.vus,
      maxVUs,
      gracefulStop: '10s',
    },
  },
  noConnectionReuse: cfg.noConnectionReuse,
  summaryTrendStats: ['avg', 'p(5)', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds: performanceThresholds(),
  tags: {
    profile: 'connection-churn',
    model: cfg.model,
    no_connection_reuse: String(cfg.noConnectionReuse),
  },
};

export default function () {
  executeRequest(__ITER);
}

export function handleSummary(data) {
  return makeSummary(data, 'connection-churn');
}
