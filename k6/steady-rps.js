import {
  cfg,
  executeRequest,
  makeSummary,
  performanceThresholds
} from './benchmark-common.js';

const targetRate = cfg.rps > 0 ? cfg.rps : 100;

export const options = {
  scenarios: {
    steady_rps: {
      executor: 'constant-arrival-rate',
      rate: targetRate,
      timeUnit: '1s',
      duration: cfg.duration,
      preAllocatedVUs: cfg.vus,
      gracefulStop: '10s',
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
    'max'
  ],

  thresholds: performanceThresholds(),

  tags: {
    profile: 'steady-rps',
    model: cfg.model,
  },
};

export default function () {
  executeRequest(__ITER);
}

export function handleSummary(data) {
  return makeSummary(data, 'steady-rps');
}