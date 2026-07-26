import { cfg, executeRequest, makeSummary } from './benchmark-common.js';

const maxRate = cfg.rps > 0 ? cfg.rps : 1000;
const stage = cfg.duration;
const rateAt = (fraction) => Math.max(1, Math.round(maxRate * fraction));
const maxVUs = Math.max(cfg.vus * 5, Math.ceil(maxRate * 1.5));

export const options = {
  scenarios: {
    saturation: {
      executor: 'ramping-arrival-rate',
      startRate: rateAt(0.05),
      timeUnit: '1s',
      preAllocatedVUs: cfg.vus,
      maxVUs,
      stages: [
        { target: rateAt(0.10), duration: stage },
        { target: rateAt(0.25), duration: stage },
        { target: rateAt(0.50), duration: stage },
        { target: rateAt(0.75), duration: stage },
        { target: maxRate, duration: stage },
        { target: maxRate, duration: stage },
        { target: 0, duration: stage },
      ],
      gracefulStop: '15s',
    },
  },
  noConnectionReuse: cfg.noConnectionReuse,
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  // Saturation is expected to cross the SLO. The shell runner evaluates the result.
  thresholds: {},
  tags: {
    profile: 'saturation',
    model: cfg.model,
  },
};

export default function () {
  executeRequest(__ITER);
}

export function handleSummary(data) {
  return makeSummary(data, 'saturation');
}
