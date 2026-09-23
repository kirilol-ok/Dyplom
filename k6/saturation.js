import {
  cfg,
  executeRequest,
  makeSummary,
} from './benchmark-common.js';

const targetRate = cfg.rps > 0 ? cfg.rps : 1000;

export const options = {
  scenarios: {
    saturation: {
      executor: 'constant-arrival-rate',
      rate: targetRate,
      timeUnit: '1s',
      duration: cfg.duration,
      preAllocatedVUs: cfg.vus,
      maxVUs: cfg.vus,
      gracefulStop: '15s',
    },
  },

  noConnectionReuse: cfg.noConnectionReuse,

  summaryTrendStats: [
    'avg',
    'p(5)',
    'med',
    'p(90)',
    'p(95)',
    'p(99)',
    'max',
  ],

  thresholds: {},

  tags: {
    profile: 'saturation',
    model: cfg.model,
    target_rps: String(targetRate),
    preallocated_vus: String(cfg.vus),
  },
};

export default function () {
  executeRequest(__ITER);
}

export function handleSummary(data) {
  return makeSummary(data, 'saturation');
}