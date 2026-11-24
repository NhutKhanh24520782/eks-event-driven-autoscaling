#!/usr/bin/env node
/**
 * Analyze Control Loop Latency (T0–T6) — Node.js implementation.
 *
 * Correlates API/worker logs and sampled Kubernetes state into experiment CSVs.
 * 
 * Usage:
 *   node scripts/metrics/analyze-control-loop-latency.js docs/evidence/<run-id>
 */

const fs = require('fs');
const path = require('path');

const JOB_ID_RE = /\bjob_id=([^\s,]+)/;
const FIELD_RE = /\b([a-z_]+)=([^\s,]+)/g;

function parseTimestamp(value) {
  if (!value) return null;
  const d = new Date(value);
  return isNaN(d.getTime()) ? null : d;
}

function isoOrEmpty(date) {
  return date ? date.toISOString() : '';
}

function intervalMs(start, end) {
  if (!start || !end) return null;
  const diff = end.getTime() - start.getTime();
  return diff < 0 ? null : Math.round(diff * 1000) / 1000;
}

function percentile(values, fraction) {
  const ordered = [...values].sort((a, b) => a - b);
  if (ordered.length === 0) return null;
  const position = (ordered.length - 1) * fraction;
  const lower = Math.floor(position);
  const upper = Math.ceil(position);
  if (lower === upper) return ordered[lower];
  return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower);
}

function readLog(filePath, jobs, logType) {
  if (!fs.existsSync(filePath)) return;
  const content = fs.readFileSync(filePath, 'utf8');
  const lines = content.split(/\r?\n/);

  for (const line of lines) {
    const jobMatch = line.match(JOB_ID_RE);
    if (!jobMatch) continue;
    const jobId = jobMatch[1];

    const fields = {};
    let m;
    while ((m = FIELD_RE.exec(line)) !== null) {
      fields[m[1]] = m[2];
    }

    if (!jobs[jobId]) {
      jobs[jobId] = { starts: [], successes: [], t0_candidates: [], t1_candidates: [] };
    }
    const entry = jobs[jobId];

    if (logType === 'api' && line.includes('[SQS SENT]')) {
      const t0 = parseTimestamp(fields.api_received_at);
      const t1 = parseTimestamp(fields.enqueued_at);
      if (t0) entry.t0_candidates.push(t0);
      if (t1) entry.t1_candidates.push(t1);
    } else if (logType === 'worker' && line.includes('[JOB START]')) {
      const started = parseTimestamp(fields.timestamp);
      if (started) entry.starts.push(started);
    } else if (logType === 'worker' && line.includes('[JOB SUCCESS]')) {
      const completed = parseTimestamp(fields.completed_at);
      const duration = fields.duration_ms;
      if (completed) {
        entry.successes.push({
          completed,
          duration_ms: duration && !isNaN(Number(duration)) ? parseFloat(duration) : null
        });
      }
    }
  }
}

function readRunEvents(filePath) {
  const events = {};
  if (!fs.existsSync(filePath)) return events;
  const lines = fs.readFileSync(filePath, 'utf8').split(/\r?\n/);
  if (lines.length < 2) return events;

  const header = lines[0].split(',').map(s => s.trim());
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    const parts = line.split(',');
    const row = {};
    header.forEach((h, idx) => { row[h] = (parts[idx] || '').trim(); });
    const mark = row.mark;
    const timestamp = parseTimestamp(row.timestamp);
    if (mark && timestamp) {
      if (!events[mark]) events[mark] = [];
      events[mark].push({
        timestamp,
        source: row.source || '',
        uncertainty_ms: row.uncertainty_ms || ''
      });
    }
  }
  return events;
}

function replicaScaleTime(filePath) {
  if (!fs.existsSync(filePath)) return null;
  const lines = fs.readFileSync(filePath, 'utf8').split(/\r?\n/);
  if (lines.length < 2) return null;

  const samples = [];
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    const parts = line.split('\t');
    if (parts.length < 2) continue;
    const timestamp = parseTimestamp(parts[0]);
    const desiredMatch = parts[1].match(/\d+/);
    if (timestamp && desiredMatch) {
      samples.push({ timestamp, desired: parseInt(desiredMatch[0], 10) });
    }
  }
  if (samples.length < 2) return null;
  const baseline = samples[0].desired;
  const scaleSample = samples.slice(1).find(s => s.desired > baseline);
  return scaleSample ? scaleSample.timestamp : null;
}

function readPods(filePath) {
  if (!fs.existsSync(filePath)) return null;
  try {
    const data = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    return data.items || [];
  } catch (e) {
    return null;
  }
}

function firstNewPod(beforePath, afterPath, observationsPath, runStarted) {
  const beforePods = readPods(beforePath) || [];
  const afterPods = readPods(afterPath) || [];
  const oldNames = new Set(beforePods.map(p => p.metadata && p.metadata.name).filter(Boolean));
  const candidates = [];

  if (fs.existsSync(observationsPath)) {
    const latestByName = {};
    const lines = fs.readFileSync(observationsPath, 'utf8').split(/\r?\n/);
    for (let i = 1; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line) continue;
      const parts = line.split('\t');
      if (parts.length < 6) continue;
      const [observedAt, name, createdText, readyStatus, readyText, node] = parts;
      const created = parseTimestamp(createdText);
      if (!created || oldNames.has(name) || (runStarted && created < runStarted)) continue;
      const ready = readyStatus === 'True' ? parseTimestamp(readyText) : null;
      const prev = latestByName[name];
      if (!prev || (ready && !prev.ready)) {
        latestByName[name] = { created, ready, name, node };
      }
    }
    candidates.push(...Object.values(latestByName));
  }

  if (candidates.length === 0 && afterPods.length > 0) {
    for (const pod of afterPods) {
      const name = pod.metadata && pod.metadata.name;
      if (!name || oldNames.has(name)) continue;
      if (pod.metadata.labels && pod.metadata.labels.app !== 'worker-service') continue;
      const created = parseTimestamp(pod.metadata.creationTimestamp);
      if (!created || (runStarted && created < runStarted)) continue;
      const readyCondition = (pod.status && pod.status.conditions || []).find(
        c => c.type === 'Ready' && c.status === 'True'
      );
      const ready = readyCondition ? parseTimestamp(readyCondition.lastTransitionTime) : null;
      const node = (pod.spec && pod.spec.nodeName) || '';
      candidates.push({ created, ready, name, node });
    }
  }

  if (candidates.length === 0) return { created: null, ready: null, name: '', node: '' };
  candidates.sort((a, b) => a.created.getTime() - b.created.getTime());
  return candidates[0];
}

function main() {
  const targetDir = process.argv[2];
  if (!targetDir) {
    console.error('Usage: node analyze-control-loop-latency.js <evidence_dir>');
    process.exit(1);
  }

  const directory = path.resolve(targetDir);
  if (!fs.existsSync(directory)) {
    console.error(`Directory not found: ${directory}`);
    process.exit(1);
  }

  const jobs = {};
  readLog(path.join(directory, 'api.log'), jobs, 'api');
  readLog(path.join(directory, 'worker.log'), jobs, 'worker');

  let runId = '';
  let runStarted = null;
  let sampleIntervalMs = '';
  const runManifestPath = path.join(directory, 'run.txt');
  if (fs.existsSync(runManifestPath)) {
    const lines = fs.readFileSync(runManifestPath, 'utf8').split(/\r?\n/);
    for (const line of lines) {
      if (line.startsWith('run_id=')) runId = line.split('=')[1].trim();
      if (line.startsWith('started_at=')) runStarted = parseTimestamp(line.split('=')[1].trim());
      if (line.startsWith('sample_interval_seconds=')) {
        sampleIntervalMs = String(parseFloat(line.split('=')[1].trim()) * 1000);
      }
    }
  }

  let filteredJobs = jobs;
  if (runId) {
    filteredJobs = {};
    for (const [id, entry] of Object.entries(jobs)) {
      if (id.includes(runId)) filteredJobs[id] = entry;
    }
  }

  const runEvents = readRunEvents(path.join(directory, 'run-events.csv'));
  const jobRows = [];
  const samples = {
    api_to_sqs_ms: [],
    worker_processing_ms: [],
    job_end_to_end_ms: []
  };

  const sortedJobIds = Object.keys(filteredJobs).sort();
  for (const jobId of sortedJobIds) {
    const entry = filteredJobs[jobId];
    const t0 = entry.t0_candidates.length ? new Date(Math.min(...entry.t0_candidates.map(d => d.getTime()))) : null;
    const t1 = entry.t1_candidates.length ? new Date(Math.min(...entry.t1_candidates.map(d => d.getTime()))) : null;
    
    entry.successes.sort((a, b) => a.completed.getTime() - b.completed.getTime());
    const success = entry.successes[0] || null;
    const t6 = success ? success.completed : null;

    const apiToSqs = intervalMs(t0, t1);
    const endToEnd = intervalMs(t0, t6);
    const processing = success ? success.duration_ms : null;

    if (apiToSqs !== null) samples.api_to_sqs_ms.push(apiToSqs);
    if (endToEnd !== null) samples.job_end_to_end_ms.push(endToEnd);
    if (processing !== null) samples.worker_processing_ms.push(processing);

    const missingMarks = [];
    if (!t0) missingMarks.push('T0');
    if (!t1) missingMarks.push('T1');
    if (!t6) missingMarks.push('T6');

    jobRows.push({
      job_id: jobId,
      T0_api_received_utc: isoOrEmpty(t0),
      T1_sqs_ack_utc: isoOrEmpty(t1),
      T6_success_utc: isoOrEmpty(t6),
      api_to_sqs_ms: apiToSqs !== null ? apiToSqs : '',
      worker_processing_ms: processing !== null ? processing : '',
      job_end_to_end_ms: endToEnd !== null ? endToEnd : '',
      missing_marks: missingMarks.join(',')
    });
  }

  // Write job-latencies.csv
  const jobColumns = [
    'job_id', 'T0_api_received_utc', 'T1_sqs_ack_utc', 'T6_success_utc',
    'api_to_sqs_ms', 'worker_processing_ms', 'job_end_to_end_ms', 'missing_marks'
  ];
  const jobCsvLines = [jobColumns.join(',')];
  for (const r of jobRows) {
    jobCsvLines.push(jobColumns.map(c => r[c] !== undefined ? r[c] : '').join(','));
  }
  fs.writeFileSync(path.join(directory, 'job-latencies.csv'), jobCsvLines.join('\n') + '\n', 'utf8');

  // Compute Run-Level Latencies
  const scaleTime = replicaScaleTime(path.join(directory, 'replicas.tsv'));
  const t2Entry = (runEvents.T2 || []).sort((a, b) => a.timestamp.getTime() - b.timestamp.getTime())[0] || null;
  const t3Entry = (runEvents.T3 || []).sort((a, b) => a.timestamp.getTime() - b.timestamp.getTime())[0] || null;
  const t3Time = t3Entry ? t3Entry.timestamp : scaleTime;

  const pod = firstNewPod(
    path.join(directory, 'worker-pods-before.json'),
    path.join(directory, 'worker-pods.json'),
    path.join(directory, 'worker-pod-observations.tsv'),
    runStarted
  );

  const t1Dates = jobRows.map(r => parseTimestamp(r.T1_sqs_ack_utc)).filter(Boolean);
  const firstT1 = t1Dates.length ? new Date(Math.min(...t1Dates.map(d => d.getTime()))) : null;
  const t2 = t2Entry ? t2Entry.timestamp : null;
  const t4 = pod.created;
  const t5 = pod.ready;

  const runRow = {
    T2_keda_observed_utc: isoOrEmpty(t2),
    T2_source: t2Entry ? t2Entry.source : '',
    T2_uncertainty_ms: t2Entry ? t2Entry.uncertainty_ms : '',
    T3_desired_replica_increase_observed_utc: isoOrEmpty(t3Time),
    T3_source: t3Entry ? t3Entry.source : (scaleTime ? '1-second replica sample' : ''),
    T3_uncertainty_ms: t3Entry ? t3Entry.uncertainty_ms : (scaleTime ? sampleIntervalMs : ''),
    T4_worker_pod_name: pod.name,
    T4_worker_node: pod.node,
    T4_first_new_worker_pod_created_utc: isoOrEmpty(t4),
    T5_first_new_worker_pod_ready_utc: isoOrEmpty(t5),
    first_enqueue_to_t2_ms: intervalMs(firstT1, t2) ?? '',
    t2_to_t3_ms: intervalMs(t2, t3Time) ?? '',
    t3_to_t4_ms: intervalMs(t3Time, t4) ?? '',
    t4_to_t5_ms: intervalMs(t4, t5) ?? '',
    first_enqueue_to_ready_ms: intervalMs(firstT1, t5) ?? ''
  };

  const runColumns = Object.keys(runRow);
  const runCsvLines = [
    runColumns.join(','),
    runColumns.map(c => runRow[c]).join(',')
  ];
  fs.writeFileSync(path.join(directory, 'run-latencies.csv'), runCsvLines.join('\n') + '\n', 'utf8');

  // Write latency-summary.csv
  const summaryLines = ['interval,count,min_ms,p50_ms,p90_ms,p95_ms,max_ms'];
  for (const [name, values] of Object.entries(samples)) {
    if (values.length === 0) {
      summaryLines.push(`${name},0,,,,,`);
    } else {
      const min = Math.min(...values);
      const max = Math.max(...values);
      const p50 = percentile(values, 0.50);
      const p90 = percentile(values, 0.90);
      const p95 = percentile(values, 0.95);
      summaryLines.push(`${name},${values.length},${min},${p50},${p90},${p95},${max}`);
    }
  }
  fs.writeFileSync(path.join(directory, 'latency-summary.csv'), summaryLines.join('\n') + '\n', 'utf8');

  // Write latency-analysis.json
  const missing = {
    jobs_without_T0: jobRows.filter(r => !r.T0_api_received_utc).length,
    jobs_without_T1: jobRows.filter(r => !r.T1_sqs_ack_utc).length,
    jobs_without_T6: jobRows.filter(r => !r.T6_success_utc).length,
    T2_unavailable: t2 === null,
    T3_unavailable: t3Time === null,
    T4_unavailable: t4 === null,
    T5_unavailable: t5 === null,
    T3_sample_observed_after_T4: Boolean(!t3Entry && scaleTime && t4 && scaleTime > t4)
  };

  const analysis = {
    run_id: runId,
    job_count: jobRows.length,
    missing_events: missing
  };
  fs.writeFileSync(path.join(directory, 'latency-analysis.json'), JSON.stringify(analysis, null, 2) + '\n', 'utf8');

  console.log(`Analyzed ${jobRows.length} correlated jobs in ${directory}`);
  console.log(`T2 observed: ${t2 ? 'yes' : 'no'}; T3-T5 are derived from sampled Kubernetes state.`);
  console.log('Wrote job-latencies.csv, run-latencies.csv, latency-summary.csv, latency-analysis.json.');
}

main();
