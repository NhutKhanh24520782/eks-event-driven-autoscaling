/**
 * Worker Service — EKS Event-Driven Autoscaling Architecture
 * Developer: Phát (Backend Engineer)
 *
 * Responsibilities:
 * - Poll messages from AWS SQS (jobs-queue) using long polling
 * - Idempotent processing (deduplicate messages using in-memory TTL cache)
 * - Configurable job processing time (simulate CPU/IO workload)
 * - Handle message retry and redelivery tracking (ApproximateReceiveCount)
 * - Graceful shutdown on SIGTERM / SIGINT (finish in-flight messages before terminating)
 * - Expose HTTP /health on port 8081 for Kubernetes Liveness / Readiness probes
 */

require('dotenv').config();
const http = require('http');
const os = require('os');
const {
  SQSClient,
  ReceiveMessageCommand,
  DeleteMessageCommand,
  CreateQueueCommand
} = require('@aws-sdk/client-sqs');

// ── Configuration ──
const AWS_REGION = process.env.AWS_REGION || 'ap-southeast-1';
const QUEUE_URL = process.env.QUEUE_URL;
const AWS_ENDPOINT_URL = process.env.AWS_ENDPOINT_URL; // For LocalStack / local testing
const HEALTH_PORT = parseInt(process.env.HEALTH_PORT || '8081', 10);
const DEFAULT_PROCESS_TIME_MS = parseInt(process.env.WORKER_PROCESS_TIME_MS || '1000', 10);
const WAIT_TIME_SECONDS = parseInt(process.env.WAIT_TIME_SECONDS || '20', 10); // SQS Long Polling
const MAX_MESSAGES = parseInt(process.env.MAX_MESSAGES || '5', 10); // Batch size 1-10
const WORKER_ID = process.env.HOSTNAME || `${os.hostname()}-${process.pid}`;
const DEDUPLICATION_TTL_MS = parseInt(process.env.DEDUPLICATION_TTL_MS || '600000', 10); // 10 minutes

// ── AWS SQS Client Initialization ──
// Uses IRSA on EKS automatically; falls back to environment variables or LocalStack
const sqsConfig = {
  region: AWS_REGION,
};

if (AWS_ENDPOINT_URL) {
  sqsConfig.endpoint = AWS_ENDPOINT_URL;
}

const sqsClient = new SQSClient(sqsConfig);

// Helper to auto-create queue on mock endpoint if needed
async function autoCreateQueueIfMock() {
  if (AWS_ENDPOINT_URL && QUEUE_URL) {
    try {
      const queueName = QUEUE_URL.split('/').pop();
      await sqsClient.send(new CreateQueueCommand({ QueueName: queueName }));
      console.log(`[INIT] SQS queue '${queueName}' confirmed on mock endpoint.`);
    } catch (e) {
      // Ignore
    }
  }
}

// ── Observability & State Tracking ──
let isShuttingDown = false;
let inFlightJobs = 0;
const metrics = {
  totalReceived: 0,
  totalProcessed: 0,
  totalDuplicates: 0,
  totalErrors: 0,
  startTime: new Date().toISOString()
};

// ── Idempotency: In-Memory Deduplication Cache with TTL ──
// SQS provides at-least-once delivery; duplicates can occur upon retry or network partition.
class IdempotencyCache {
  constructor(ttlMs = DEDUPLICATION_TTL_MS) {
    this.cache = new Map(); // key -> timestamp
    this.ttlMs = ttlMs;

    // Periodic cleanup of expired records every 60s
    this.cleanupTimer = setInterval(() => this.cleanup(), 60000);
    this.cleanupTimer.unref();
  }

  isDuplicate(jobId) {
    if (!jobId) return false;
    const now = Date.now();
    const entryTime = this.cache.get(jobId);
    if (entryTime && (now - entryTime) < this.ttlMs) {
      return true;
    }
    return false;
  }

  record(jobId) {
    if (!jobId) return;
    this.cache.set(jobId, Date.now());
  }

  cleanup() {
    const now = Date.now();
    for (const [jobId, timestamp] of this.cache.entries()) {
      if (now - timestamp > this.ttlMs) {
        this.cache.delete(jobId);
      }
    }
  }
}

const deduplicationCache = new IdempotencyCache();

// ── Job Processing Logic ──
async function processSingleMessage(message) {
  const messageId = message.MessageId;
  const receiptHandle = message.ReceiptHandle;
  const receiveCount = parseInt(
    (message.Attributes && message.Attributes.ApproximateReceiveCount) || '1',
    10
  );

  let jobData = {};
  try {
    jobData = JSON.parse(message.Body || '{}');
  } catch (parseErr) {
    console.error(`[WORKER ${WORKER_ID}] [MALFORMED] Failed to parse message body:`, message.Body);
    // Malformed message can't be parsed; delete it to avoid poisoning queue
    await deleteMessage(receiptHandle, messageId);
    return;
  }

  const jobId = jobData.job_id || jobData.jobId || messageId;
  const processTimeMs = typeof jobData.processTimeMs === 'number'
    ? jobData.processTimeMs
    : DEFAULT_PROCESS_TIME_MS;
  const shouldFail = !!jobData.shouldFail;

  // 1. Idempotency Check (Duplicate message handling)
  if (deduplicationCache.isDuplicate(jobId)) {
    metrics.totalDuplicates++;
    console.warn(
      `[WORKER ${WORKER_ID}] [IDEMPOTENT SKIP] Duplicate detected for job_id=${jobId} ` +
      `(message_id=${messageId}, receive_count=${receiveCount}). Deleting without reprocessing.`
    );
    // Delete duplicate so it won't keep recurring
    await deleteMessage(receiptHandle, messageId);
    return;
  }

  // 2. Retry / Redelivery Warning
  if (receiveCount > 1) {
    console.warn(
      `[WORKER ${WORKER_ID}] [REDELIVERY] Message is being retried! ` +
      `job_id=${jobId}, receive_count=${receiveCount}, message_id=${messageId}`
    );
  }

  // 3. Process the job
  const jobStartTime = Date.now();
  console.log(
    `[WORKER ${WORKER_ID}] [JOB START] job_id=${jobId} message_id=${messageId} ` +
    `receive_count=${receiveCount} process_time_ms=${processTimeMs} ` +
    `timestamp=${new Date(jobStartTime).toISOString()}`
  );

  inFlightJobs++;
  try {
    // Simulate workload (CPU or I/O task)
    await new Promise((resolve, reject) => {
      setTimeout(() => {
        if (shouldFail) {
          reject(new Error(`Simulated job failure requested for job_id=${jobId}`));
        } else {
          resolve();
        }
      }, processTimeMs);
    });

    const durationMs = Date.now() - jobStartTime;
    metrics.totalProcessed++;
    deduplicationCache.record(jobId);

    console.log(
      `[WORKER ${WORKER_ID}] [JOB SUCCESS] job_id=${jobId} duration_ms=${durationMs} ` +
      `total_processed=${metrics.totalProcessed}`
    );

    // 4. Delete successfully processed message from SQS
    await deleteMessage(receiptHandle, messageId);

  } catch (error) {
    metrics.totalErrors++;
    console.error(
      `[WORKER ${WORKER_ID}] [JOB FAILURE] job_id=${jobId} receive_count=${receiveCount} ` +
      `error=${error.message}. Leaving message in SQS for redelivery or DLQ.`
    );
    // Intentionally DO NOT delete message from SQS.
    // SQS visibility timeout will expire, allowing message to be redelivered.
    // If receive_count exceeds maxReceiveCount, SQS routes it automatically to DLQ.
  } finally {
    inFlightJobs--;
  }
}

// ── SQS Delete Helper ──
async function deleteMessage(receiptHandle, messageId) {
  try {
    const deleteCmd = new DeleteMessageCommand({
      QueueUrl: QUEUE_URL,
      ReceiptHandle: receiptHandle
    });
    await sqsClient.send(deleteCmd);
    console.log(`[WORKER ${WORKER_ID}] [DELETED] message_id=${messageId} removed from queue.`);
  } catch (deleteErr) {
    console.error(`[WORKER ${WORKER_ID}] [DELETE ERROR] Failed to delete message ${messageId}:`, deleteErr);
  }
}

// ── Main Polling Loop ──
async function startPollingLoop() {
  console.log(`====================================================`);
  console.log(`  Worker Service started`);
  console.log(`  Worker ID:        ${WORKER_ID}`);
  console.log(`  AWS Region:       ${AWS_REGION}`);
  console.log(`  Queue URL:        ${QUEUE_URL || '(NOT SET)'}`);
  console.log(`  Poll Wait Time:   ${WAIT_TIME_SECONDS}s (Long Polling)`);
  console.log(`  Batch Size:       ${MAX_MESSAGES}`);
  console.log(`  Default Work:     ${DEFAULT_PROCESS_TIME_MS}ms`);
  console.log(`  Health Check:     http://0.0.0.0:${HEALTH_PORT}/health`);
  console.log(`====================================================`);

  if (!QUEUE_URL) {
    console.error('[FATAL] QUEUE_URL is not set. Worker cannot poll without QUEUE_URL.');
    return;
  }

  await autoCreateQueueIfMock();

  while (!isShuttingDown) {
    try {
      const receiveCmd = new ReceiveMessageCommand({
        QueueUrl: QUEUE_URL,
        MaxNumberOfMessages: MAX_MESSAGES,
        WaitTimeSeconds: WAIT_TIME_SECONDS,
        AttributeNames: ['All'],
        MessageAttributeNames: ['All']
      });

      const response = await sqsClient.send(receiveCmd);
      const messages = response.Messages || [];

      if (messages.length > 0) {
        metrics.totalReceived += messages.length;
        console.log(`[WORKER ${WORKER_ID}] [POLL] Received ${messages.length} message(s) from SQS.`);

        // Process batch concurrently
        await Promise.all(messages.map(msg => processSingleMessage(msg)));
      }
    } catch (pollError) {
      if (isShuttingDown) break;
      console.error(`[WORKER ${WORKER_ID}] [POLL ERROR]:`, pollError.message);
      // Wait 3 seconds before retrying on network/client errors
      await new Promise(res => setTimeout(res, 3000));
    }
  }

  console.log(`[WORKER ${WORKER_ID}] Polling loop exited.`);
}

// ── Lightweight Health & Observability HTTP Server ──
const healthServer = http.createServer((req, res) => {
  if (req.url === '/health' || req.url === '/healthz') {
    const isHealthy = !isShuttingDown;
    res.writeHead(isHealthy ? 200 : 503, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: isHealthy ? 'healthy' : 'shutting_down',
      service: 'worker-service',
      worker_id: WORKER_ID,
      in_flight_jobs: inFlightJobs,
      total_received: metrics.totalReceived,
      total_processed: metrics.totalProcessed,
      total_duplicates: metrics.totalDuplicates,
      total_errors: metrics.totalErrors,
      uptime_seconds: Math.floor(process.uptime()),
      timestamp: new Date().toISOString()
    }));
    return;
  }

  if (req.url === '/metrics') {
    res.writeHead(200, { 'Content-Type': 'text/plain; version=0.0.4' });
    const output = [
      `# HELP worker_in_flight_jobs Current in-flight jobs being processed`,
      `# TYPE worker_in_flight_jobs gauge`,
      `worker_in_flight_jobs ${inFlightJobs}`,
      `# HELP worker_jobs_processed_total Total jobs successfully processed`,
      `# TYPE worker_jobs_processed_total counter`,
      `worker_jobs_processed_total ${metrics.totalProcessed}`,
      `# HELP worker_jobs_duplicate_total Total duplicate jobs skipped`,
      `# TYPE worker_jobs_duplicate_total counter`,
      `worker_jobs_duplicate_total ${metrics.totalDuplicates}`,
      `# HELP worker_jobs_error_total Total jobs failed`,
      `# TYPE worker_jobs_error_total counter`,
      `worker_jobs_error_total ${metrics.totalErrors}`
    ].join('\n');
    res.end(output);
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'NotFound' }));
});

healthServer.listen(HEALTH_PORT, '0.0.0.0', () => {
  console.log(`[HEALTH] Health check server listening on port ${HEALTH_PORT}`);
});

// ── Graceful Shutdown Handler ──
function initiateGracefulShutdown(signal) {
  if (isShuttingDown) return;
  isShuttingDown = true;
  console.log(`\n[SHUTDOWN] Received ${signal}. Stopping SQS polling loop...`);

  // Close health server so Kubernetes readiness probe immediately fails
  healthServer.close(() => {
    console.log('[SHUTDOWN] Health check HTTP server closed.');
  });

  // Wait for all in-flight jobs to finish cleanly
  const checkInterval = 500;
  const maxWaitMs = 25000; // 25 seconds (K8s terminationGracePeriodSeconds is typically 30s)
  let waitedMs = 0;

  const waitTimer = setInterval(() => {
    waitedMs += checkInterval;
    if (inFlightJobs === 0) {
      clearInterval(waitTimer);
      console.log(`[SHUTDOWN] All in-flight jobs finished cleanly (${metrics.totalProcessed} total processed).`);
      process.exit(0);
    }

    console.log(`[SHUTDOWN] Waiting for ${inFlightJobs} in-flight job(s) to finish (${waitedMs}ms / ${maxWaitMs}ms)...`);

    if (waitedMs >= maxWaitMs) {
      clearInterval(waitTimer);
      console.warn(`[SHUTDOWN] Timeout reached with ${inFlightJobs} active job(s). Forcing shutdown.`);
      process.exit(1);
    }
  }, checkInterval);
}

process.on('SIGTERM', () => initiateGracefulShutdown('SIGTERM'));
process.on('SIGINT', () => initiateGracefulShutdown('SIGINT'));

// Start polling
startPollingLoop();
