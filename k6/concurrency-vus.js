import { sleep } from 'k6';
import {
  cfg,
  executeRequest,
  makeSummary,
  performanceThresholds,
} from './benchmark-common.js';

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

  summaryTrendStats: [
    'avg',
    'p(5)',
    'med',
    'p(90)',
    'p(95)',
    'p(99)',
    'max',
  ],

  thresholds: performanceThresholds(),

  tags: {
    profile: 'concurrency-vus',
    model: cfg.model,
  },
};

export default function () {
  executeRequest(__ITER);

  if (cfg.sleepMs > 0) {
    sleep(cfg.sleepMs / 1000);
  }
}

export function handleSummary(data) {
  return makeSummary(data, 'concurrency-vus');
}