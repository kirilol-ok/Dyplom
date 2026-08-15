import { cfg, executeRequest, makeSummary, standardThresholds } from './benchmark-common.js';

const targetRate = cfg.rps > 0 ? cfg.rps : 200;

export const options = {
  scenarios: {
    connection_churn: {
      executor: 'constant-arrival-rate',
      rate: targetRate,
      timeUnit: '1s',
      duration: cfg.duration,
      preAllocatedVUs: cfg.vus,
      maxVUs: cfg.maxVUs,
      gracefulStop: '10s',
    },
  },
  noConnectionReuse: cfg.noConnectionReuse,
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds: standardThresholds(true),
  tags: { profile: 'connection-churn', model: cfg.model, target_rps: String(targetRate) },
};

export default function () { executeRequest(__ITER); }
export function handleSummary(data) { return makeSummary(data, 'connection-churn'); }
