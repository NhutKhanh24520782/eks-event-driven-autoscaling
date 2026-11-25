import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const API_URL = (__ENV.API_URL || 'http://localhost:3000').replace(/\/+$/, '');
const RUN_ID = __ENV.RUN_ID || `k6-${new Date().toISOString().replace(/[-:.]/g, '')}`;
const PROFILE = __ENV.K6_PROFILE || 'load';

function positiveInteger(name, defaultValue, maximum) {
  const value = Number(__ENV[name] || defaultValue);
  if (!Number.isInteger(value) || value <= 0 || value > maximum) {
    throw new Error(`${name} must be an integer between 1 and ${maximum}`);
  }
  return value;
}

function durationValue(name, defaultValue) {
  const value = __ENV[name] || defaultValue;
  if (!/^\d+(ms|s|m)$/.test(value)) {
    throw new Error(`${name} must be a duration such as 500ms, 30s, or 2m`);
  }
  return value;
}

const PROCESS_TIME_MS = positiveInteger('PROCESS_TIME_MS', 1000, 60000);
const BASELINE_VUS = positiveInteger('BASELINE_VUS', 1, 50);
const PEAK_VUS = positiveInteger('PEAK_VUS', 10, 50);
const SPIKE_VUS = positiveInteger('SPIKE_VUS', 20, 50);
const BASELINE_DURATION = durationValue('BASELINE_DURATION', '30s');
const RAMP_UP_DURATION = durationValue('RAMP_UP_DURATION', '60s');
const HOLD_DURATION = durationValue('HOLD_DURATION', '120s');
const RAMP_DOWN_DURATION = durationValue('RAMP_DOWN_DURATION', '30s');
const SOAK_DURATION = durationValue('SOAK_DURATION', '3m');
const REQUEST_PAUSE_SECONDS = Number(__ENV.REQUEST_PAUSE_SECONDS || (PROFILE === 'smoke' ? 0.1 : 1));
const FAILURE_RATE = Math.min(1.0, Math.max(0.0, Number(__ENV.FAILURE_RATE || 0.0)));
const TIMESTAMP_PRECISION_GUARD_MS = 2;

const VALID_PROFILES = ['smoke', 'baseline', 'load', 'spike', 'stress', 'soak'];
if (!VALID_PROFILES.includes(PROFILE)) {
  throw new Error(`K6_PROFILE must be one of: ${VALID_PROFILES.join(', ')}`);
}
if (!Number.isFinite(REQUEST_PAUSE_SECONDS) ||
  REQUEST_PAUSE_SECONDS < 0 ||
  REQUEST_PAUSE_SECONDS > 60) {
  throw new Error('REQUEST_PAUSE_SECONDS must be between 0 and 60');
}

const enqueueAckMs = new Trend('enqueue_ack_ms', true);
const acceptedJobs = new Counter('accepted_jobs');
const rejectedJobs = new Counter('rejected_jobs');

const stagesByProfile = {
  smoke: [
    { duration: '2s', target: 1 },
    { duration: '2s', target: 0 },
  ],
  baseline: [
    { duration: '5s', target: BASELINE_VUS },
    { duration: BASELINE_DURATION, target: BASELINE_VUS },
    { duration: '5s', target: 0 },
  ],
  load: [
    { duration: BASELINE_DURATION, target: 1 },
    { duration: RAMP_UP_DURATION, target: PEAK_VUS },
    { duration: HOLD_DURATION, target: PEAK_VUS },
    { duration: RAMP_DOWN_DURATION, target: 0 },
  ],
  spike: [
    { duration: '5s', target: 1 },
    { duration: '5s', target: SPIKE_VUS },
    { duration: '30s', target: SPIKE_VUS },
    { duration: '10s', target: 1 },
    { duration: '5s', target: 0 },
  ],
  stress: [
    { duration: '20s', target: PEAK_VUS },
    { duration: '40s', target: Math.min(50, PEAK_VUS * 2) },
    { duration: '60s', target: Math.min(50, PEAK_VUS * 2) },
    { duration: '30s', target: 0 },
  ],
  soak: [
    { duration: '15s', target: Math.min(10, BASELINE_VUS * 3) },
    { duration: SOAK_DURATION, target: Math.min(10, BASELINE_VUS * 3) },
    { duration: '15s', target: 0 },
  ],
};

export const options = {
  tags: { run_id: RUN_ID, profile: PROFILE },
  stages: stagesByProfile[PROFILE],
  thresholds: {
    'accepted_jobs': ['count>0'],
    'enqueue_ack_ms': ['p(95)<2000'],
  },
};

export function setup() {
  let bestSample = null;
  for (let attempt = 0; attempt < 5; attempt++) {
    const sentAt = Date.now();
    const res = http.get(`${API_URL}/health`, { tags: { endpoint: 'clock-sync' } });
    const receivedAt = Date.now();
    if (res.status !== 200) {
      throw new Error(`Clock sync health check failed with HTTP ${res.status}`);
    }

    const response = res.json();
    const serverTime = response && response.timestamp
      ? new Date(response.timestamp).getTime()
      : NaN;
    if (!Number.isFinite(serverTime)) {
      throw new Error('Clock sync health response did not contain a valid timestamp');
    }

    const roundTripMs = receivedAt - sentAt;
    const sample = {
      clockSkewMs: Math.round(serverTime - ((sentAt + receivedAt) / 2)) - TIMESTAMP_PRECISION_GUARD_MS,
      clockUncertaintyMs: Math.ceil(roundTripMs / 2) + TIMESTAMP_PRECISION_GUARD_MS,
      roundTripMs,
    };
    if (!bestSample || sample.roundTripMs < bestSample.roundTripMs) {
      bestSample = sample;
    }
  }

  if (!bestSample || bestSample.roundTripMs > 2000) {
    throw new Error('Clock sync failed: no API health response within 2000ms');
  }

  console.log(
    `Clock offset estimated at ${bestSample.clockSkewMs}ms ` +
    `(uncertainty <= ${bestSample.clockUncertaintyMs}ms, best RTT ${bestSample.roundTripMs}ms)`
  );
  return bestSample;
}

export default function (data) {
  const clockSkewMs = (data && typeof data.clockSkewMs === 'number') ? data.clockSkewMs : 0;
  // Align client timestamps to the API clock using the bounded setup-time estimate.
  const clientSentAt = new Date(Date.now() + clockSkewMs).toISOString();
  const jobId = `${RUN_ID}-vu${__VU}-iter${__ITER}`;
  const shouldFail = FAILURE_RATE > 0 && Math.random() < FAILURE_RATE;
  const payload = JSON.stringify({
    job_id: jobId,
    client_sent_at: clientSentAt,
    processTimeMs: PROCESS_TIME_MS,
    shouldFail: shouldFail,
    payload: { example: 'k6 test data', run_id: RUN_ID, profile: PROFILE }
  });

  const params = {
    headers: { 'Content-Type': 'application/json' },
    tags: { endpoint: 'POST /jobs', profile: PROFILE },
  };

  const res = http.post(`${API_URL}/jobs`, payload, params);

  const accepted = check(res, {
    'job accepted (HTTP 202)': (r) => r.status === 202,
  });
  enqueueAckMs.add(res.timings.duration);
  if (accepted) {
    acceptedJobs.add(1);
  } else {
    rejectedJobs.add(1);
  }

  sleep(REQUEST_PAUSE_SECONDS);
}