import { sleep } from 'k6';
import {
  cfg,
  executeRequest,
  makeSummary,
  verificationThresholds,
} from './benchmark-common.js';

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

  summaryTrendStats: [
    'avg',
    'p(5)',
    'med',
    'p(90)',
    'p(95)',
    'p(99)',
    'max',
  ],

  thresholds: verificationThresholds(),

  tags: {
    profile: 'policy',
    model: cfg.model,
  },
};

export default function () {
  executeRequest(__ITER);

  const pauseMs = cfg.sleepMs > 0 ? cfg.sleepMs : 200;
  sleep(pauseMs / 1000);
}

export function handleSummary(data) {
  return makeSummary(data, 'policy');
}