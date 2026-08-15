import { cfg, executeRequest, makeSummary } from './benchmark-common.js';

const maxRate = cfg.rps > 0 ? cfg.rps : 3000;
const stage = cfg.duration;
const rateAt = (fraction) => Math.max(1, Math.round(maxRate * fraction));

export const options = {
  scenarios: {
    saturation: {
      executor: 'ramping-arrival-rate',
      startRate: rateAt(0.10),
      timeUnit: '1s',
      preAllocatedVUs: cfg.vus,
      maxVUs: cfg.maxVUs,
      stages: [
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
  thresholds: {},
  tags: { profile: 'saturation', model: cfg.model, max_rps: String(maxRate) },
};

export default function () { executeRequest(__ITER); }
export function handleSummary(data) { return makeSummary(data, 'saturation'); }
