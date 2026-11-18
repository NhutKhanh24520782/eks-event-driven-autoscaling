/**
 * API Service — EKS Event-Driven Autoscaling Architecture
 * Developer: Phát (Backend Engineer)
 *
 * Responsibilities:
 * - Accept HTTP requests on POST /jobs
 * - Validate request payload
 * - Publish message to AWS SQS (jobs-queue)
 * - Expose GET /health for Kubernetes Liveness/Readiness probes
 * - Handle SIGTERM / SIGINT for graceful shutdown
 */

require('dotenv').config();
const express = require('express');
const {
  SQSClient,
  SendMessageCommand,
  CreateQueueCommand,
  GetQueueAttributesCommand
} = require('@aws-sdk/client-sqs');
const { v4: uuidv4 } = require('uuid');

const app = express();
app.use(express.json());

// ── Configuration ──
const PORT = parseInt(process.env.PORT || '8080', 10);
const AWS_REGION = process.env.AWS_REGION || 'ap-southeast-1';
const QUEUE_URL = process.env.QUEUE_URL;
const AWS_ENDPOINT_URL = process.env.AWS_ENDPOINT_URL; // For LocalStack / local testing
const CHAOS_ENABLED = process.env.CHAOS_ENABLED === 'true';
const CHAOS_ENVIRONMENT = process.env.CHAOS_ENVIRONMENT || '';

// ── AWS SQS Client Initialization ──
// When running in EKS, credentials are automatically resolved via IRSA
// (IAM Roles for Service Accounts) through the AWS OIDC WebIdentity token.
const sqsConfig = {
  region: AWS_REGION,
};

if (AWS_ENDPOINT_URL) {
  sqsConfig.endpoint = AWS_ENDPOINT_URL;
}

const sqsClient = new SQSClient(sqsConfig);

function escapePrometheusLabel(value) {
  return String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
}

function queueAttributeGauge(name, help, value, queueName) {
  return [
    `# HELP ${name} ${help}`,
    `# TYPE ${name} gauge`,
    `${name}{queue="${escapePrometheusLabel(queueName)}"} ${Number(value) || 0}`
  ];
}

const chaosScenarioDefinitions = {
  'traffic-spike': {
    maxJobs: 20,
    batchSize: 1,
    intervalMs: 500,
    processTimeMs: 1500,
    transport: 'api'
  },
  'sqs-backlog-spike': {
    maxJobs: 12,
    batchSize: 2,
    intervalMs: 1000,
    processTimeMs: 5000,
    transport: 'sqs'
  }
};

function isLocalSqsEndpoint(endpoint) {
  if (!endpoint) return false;
  try {
    return ['localhost', '127.0.0.1', 'sqs'].includes(new URL(endpoint).hostname);
  } catch (error) {
    return false;
  }
}

function isAwsSqsQueueUrl(queueUrl) {
  if (!queueUrl) return false;
  try {
    const url = new URL(queueUrl);
    return url.protocol === 'https:' &&
      url.hostname === `sqs.${AWS_REGION}.amazonaws.com`;
  } catch (error) {
    return false;
  }
}

const localChaosEnvironment = CHAOS_ENVIRONMENT === 'local' &&
  isLocalSqsEndpoint(AWS_ENDPOINT_URL);
const eksChaosEnvironment = CHAOS_ENVIRONMENT === 'eks-test' &&
  !AWS_ENDPOINT_URL &&
  isAwsSqsQueueUrl(QUEUE_URL);
const chaosAvailable = CHAOS_ENABLED &&
  Boolean(QUEUE_URL) &&
  (localChaosEnvironment || eksChaosEnvironment);
const chaosDisabledReason =
  'Chaos requires CHAOS_ENABLED=true, QUEUE_URL, and either local mode with a local SQS endpoint or eks-test mode using AWS SQS.';
let activeChaosRun = null;
const latestChaosRuns = new Map();

function serializeChaosRun(run) {
  return {
    id: run.id,
    status: run.status,
    sentJobs: run.sentJobs,
    maxJobs: run.maxJobs,
    processTimeMs: run.processTimeMs,
    startedAt: run.startedAt,
    finishedAt: run.finishedAt || null,
    error: run.error || null
  };
}

function finishChaosRun(run, status, error) {
  if (run.timer) clearTimeout(run.timer);
  run.timer = null;
  run.status = status;
  run.finishedAt = new Date().toISOString();
  run.error = error || null;
  if (activeChaosRun === run) activeChaosRun = null;
  latestChaosRuns.set(run.scenarioId, run);
  console.log(
    `[CHAOS] scenario=${run.scenarioId} run_id=${run.id} status=${status} ` +
    `sent_jobs=${run.sentJobs}/${run.maxJobs}${error ? ` error=${error}` : ''}`
  );
}

async function publishChaosBatch(run, definition) {
  for (let index = 0; index < definition.batchSize; index++) {
    if (run.status !== 'running' || run.sentJobs >= run.maxJobs) break;

    const jobId = `chaos-${run.id}-${run.sentJobs + 1}`;
    const createdAt = new Date().toISOString();
    const message = {
      job_id: jobId,
      payload: {
        source: 'rca-lab',
        scenario_id: run.scenarioId,
        run_id: run.id
      },
      processTimeMs: run.processTimeMs,
      shouldFail: false,
      createdAt,
      client_sent_at: createdAt
    };

    if (definition.transport === 'api') {
      const response = await fetch(`http://127.0.0.1:${PORT}/jobs`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          job_id: jobId,
          payload: message.payload,
          processTimeMs: message.processTimeMs,
          client_sent_at: createdAt
        })
      });
      if (!response.ok) {
        const result = await response.json();
        throw new Error(result.message || `Local API returned HTTP ${response.status}`);
      }
    } else {
      await sqsClient.send(new SendMessageCommand({
        QueueUrl: QUEUE_URL,
        MessageBody: JSON.stringify(message),
        MessageAttributes: {
          JobId: { DataType: 'String', StringValue: jobId },
          CreatedAt: { DataType: 'String', StringValue: createdAt }
        }
      }));
    }
    run.sentJobs++;
    console.log(
      `[CHAOS] scenario=${run.scenarioId} run_id=${run.id} ` +
      `job_id=${jobId} sent_jobs=${run.sentJobs}/${run.maxJobs}`
    );
  }
}

function scheduleChaosBatch(run, definition) {
  run.timer = setTimeout(async () => {
    if (run.status !== 'running') return;

    try {
      await publishChaosBatch(run, definition);
      if (run.status !== 'running') return;
      if (run.sentJobs >= run.maxJobs) {
        finishChaosRun(run, 'completed');
        return;
      }
      scheduleChaosBatch(run, definition);
    } catch (error) {
      finishChaosRun(run, 'failed', error.message);
    }
  }, definition.intervalMs);
  run.timer.unref();
}

// Helper to auto-create queue in local development / mock environments
async function autoCreateQueueIfMock() {
  if (AWS_ENDPOINT_URL && QUEUE_URL) {
    try {
      const queueName = QUEUE_URL.split('/').pop();
      console.log(`[INIT] Checking/creating SQS queue '${queueName}' on mock endpoint...`);
      await sqsClient.send(new CreateQueueCommand({ QueueName: queueName }));
      console.log(`[INIT] SQS queue '${queueName}' is ready.`);
    } catch (e) {
      console.warn(`[INIT] Notice on queue check: ${e.message}`);
    }
  }
}
autoCreateQueueIfMock();

// ── Request Logger Middleware ──
app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    const duration = Date.now() - start;
    console.log(`[HTTP] ${req.method} ${req.originalUrl} ${res.statusCode} ${duration}ms`);
  });
  next();
});

// ── Route: Root Info ──
app.get('/', (req, res) => {
  res.json({
    service: 'api-service',
    status: 'running',
    version: '1.0.0',
    region: AWS_REGION,
    queueConfigured: !!QUEUE_URL,
    endpoints: {
      health: 'GET /health',
      createJob: 'POST /jobs'
    }
  });
});

app.get('/chaos/scenarios', (req, res) => {
  const supportedIds = Object.keys(chaosScenarioDefinitions);
  const scenarios = supportedIds.map((id) => {
    const run = latestChaosRuns.get(id);
    return {
      id,
      supported: chaosAvailable,
      status: run ? run.status : 'idle',
      run: run ? serializeChaosRun(run) : null
    };
  });

  res.json({
    enabled: chaosAvailable,
    environment: CHAOS_ENVIRONMENT || 'unset',
    reason: chaosAvailable ? null : chaosDisabledReason,
    scenarios
  });
});

app.post('/chaos/scenarios/:id/start', async (req, res) => {
  if (!chaosAvailable) {
    return res.status(403).json({
      error: 'ChaosDisabled',
      message: chaosDisabledReason
    });
  }

  const scenarioId = req.params.id;
  if (!Object.prototype.hasOwnProperty.call(chaosScenarioDefinitions, scenarioId)) {
    return res.status(404).json({
      error: 'UnsupportedScenario',
      message: 'This scenario is not available in the configured Chaos environment.'
    });
  }
  const definition = chaosScenarioDefinitions[scenarioId];
  if (activeChaosRun) {
    return res.status(409).json({
      error: 'ScenarioAlreadyRunning',
      message: `Scenario '${activeChaosRun.scenarioId}' is already running.`,
      activeScenarioId: activeChaosRun.scenarioId
    });
  }

  const run = {
    id: uuidv4(),
    scenarioId,
    status: 'running',
    sentJobs: 0,
    maxJobs: definition.maxJobs,
    processTimeMs: definition.processTimeMs,
    startedAt: new Date().toISOString(),
    timer: null,
    error: null
  };
  activeChaosRun = run;
  latestChaosRuns.set(scenarioId, run);

  try {
    await publishChaosBatch(run, definition);
    if (run.sentJobs >= run.maxJobs) {
      finishChaosRun(run, 'completed');
    } else {
      scheduleChaosBatch(run, definition);
    }
    return res.status(202).json({ scenario: serializeChaosRun(run) });
  } catch (error) {
    finishChaosRun(run, 'failed', error.message);
    console.error(`[CHAOS] Failed to start scenario '${scenarioId}':`, error);
    return res.status(503).json({
      error: 'ChaosStartFailed',
      message: error.message || 'Failed to enqueue Chaos test jobs.'
    });
  }
});

app.post('/chaos/scenarios/:id/stop', (req, res) => {
  if (!chaosAvailable) {
    return res.status(403).json({
      error: 'ChaosDisabled',
      message: chaosDisabledReason
    });
  }

  const scenarioId = req.params.id;
  const run = latestChaosRuns.get(scenarioId);
  if (!run || run.status !== 'running' || activeChaosRun !== run) {
    return res.status(409).json({
      error: 'ScenarioNotRunning',
      message: `Scenario '${scenarioId}' is not currently running.`
    });
  }

  finishChaosRun(run, 'stopped');
  return res.json({
    scenario: serializeChaosRun(run),
    message: 'Stopped future batches. A batch already in progress may finish, and jobs already accepted by SQS may still be processed.'
  });
});

// ── Route: Health Check (Kubernetes Liveness / Readiness) ──
app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'healthy',
    service: 'api-service',
    uptime: Math.floor(process.uptime()),
    timestamp: new Date().toISOString(),
    queueConfigured: !!QUEUE_URL
  });
});

app.get('/metrics', async (req, res) => {
  if (!QUEUE_URL) {
    return res.status(503).type('text/plain').send('QUEUE_URL is not configured\n');
  }

  try {
    const result = await sqsClient.send(new GetQueueAttributesCommand({
      QueueUrl: QUEUE_URL,
      AttributeNames: [
        'ApproximateNumberOfMessages',
        'ApproximateNumberOfMessagesNotVisible',
        'ApproximateNumberOfMessagesDelayed'
      ]
    }));
    const attributes = result.Attributes || {};
    const queueName = QUEUE_URL.split('/').pop() || 'unknown';
    const output = [
      ...queueAttributeGauge(
        'api_sqs_approximate_messages_visible',
        'Approximate number of visible messages in the SQS queue',
        attributes.ApproximateNumberOfMessages,
        queueName
      ),
      ...queueAttributeGauge(
        'api_sqs_approximate_messages_not_visible',
        'Approximate number of in-flight messages in the SQS queue',
        attributes.ApproximateNumberOfMessagesNotVisible,
        queueName
      ),
      ...queueAttributeGauge(
        'api_sqs_approximate_messages_delayed',
        'Approximate number of delayed messages in the SQS queue',
        attributes.ApproximateNumberOfMessagesDelayed,
        queueName
      )
    ].join('\n');

    return res.type('text/plain').send(`${output}\n`);
  } catch (error) {
    console.error('[METRICS] Failed to read SQS queue attributes:', error);
    return res.status(503).type('text/plain').send('Unable to read SQS queue attributes\n');
  }
});

// ── Route: POST /jobs ──
// Accepts job requests and sends messages to SQS
app.post('/jobs', async (req, res) => {
  const apiReceivedAt = new Date().toISOString();
  try {
    if (!QUEUE_URL) {
      console.error('[ERROR] QUEUE_URL environment variable is not defined.');
      return res.status(500).json({
        error: 'QueueConfigurationError',
        message: 'QUEUE_URL environment variable is not configured on server'
      });
    }

    const body = req.body || {};

    // Validate payload
    if (typeof body !== 'object' || Array.isArray(body)) {
      return res.status(400).json({
        error: 'InvalidPayload',
        message: 'Request body must be a valid JSON object'
      });
    }

    // Assign or use existing job_id
    const jobId = body.job_id || body.jobId || uuidv4();
    const createdAt = apiReceivedAt;
    const clientSentAt = typeof body.client_sent_at === 'string' ? body.client_sent_at : null;
    const processTimeMs = typeof body.processTimeMs === 'number' ? body.processTimeMs : 1000;
    const shouldFail = !!body.shouldFail;

    // Structured message payload according to Integration Contract
    const messagePayload = {
      job_id: jobId,
      payload: body.payload || body,
      processTimeMs: processTimeMs,
      shouldFail: shouldFail,
      createdAt: createdAt,
      client_sent_at: clientSentAt
    };

    const messageBodyString = JSON.stringify(messagePayload);

    // Send Message to SQS
    const sendCommand = new SendMessageCommand({
      QueueUrl: QUEUE_URL,
      MessageBody: messageBodyString,
      MessageAttributes: {
        JobId: {
          DataType: 'String',
          StringValue: jobId
        },
        CreatedAt: {
          DataType: 'String',
          StringValue: createdAt
        }
      }
    });

    const sqsResponse = await sqsClient.send(sendCommand);
    const enqueuedAt = new Date().toISOString();

    console.log(
      `[SQS SENT] job_id=${jobId} message_id=${sqsResponse.MessageId} ` +
      `api_received_at=${apiReceivedAt} enqueued_at=${enqueuedAt} target_queue=${QUEUE_URL}`
    );

    // Return 202 Accepted per integration contract
    return res.status(202).json({
      status: 'accepted',
      job_id: jobId,
      message_id: sqsResponse.MessageId,
      processTimeMs: processTimeMs,
      timestamp: createdAt,
      api_received_at: apiReceivedAt,
      enqueued_at: enqueuedAt
    });

  } catch (error) {
    console.error('[ERROR] Failed to send message to SQS:', error);
    return res.status(503).json({
      error: 'SQSSendFailed',
      message: error.message || 'Failed to dispatch job to SQS queue'
    });
  }
});

// ── Start HTTP Server ──
const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(`====================================================`);
  console.log(`  API Service started successfully`);
  console.log(`  Port:         ${PORT}`);
  console.log(`  Region:       ${AWS_REGION}`);
  console.log(`  Queue URL:    ${QUEUE_URL || '(NOT SET - check env vars)'}`);
  console.log(`  LocalStack:   ${AWS_ENDPOINT_URL || 'Disabled (Using AWS IRSA)'}`);
  console.log(`====================================================`);
});

// ── Graceful Shutdown Handler ──
let isShuttingDown = false;

function gracefulShutdown(signal) {
  if (isShuttingDown) return;
  isShuttingDown = true;
  console.log(`[SHUTDOWN] Received ${signal}. Closing HTTP server gracefully...`);

  server.close((err) => {
    if (err) {
      console.error('[SHUTDOWN] Error while closing HTTP server:', err);
      process.exit(1);
    }
    console.log('[SHUTDOWN] HTTP server closed cleanly. Exiting.');
    process.exit(0);
  });

  // Force shutdown if taking longer than 10s
  setTimeout(() => {
    console.error('[SHUTDOWN] Force exiting after 10s timeout.');
    process.exit(1);
  }, 10000).unref();
}

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

module.exports = app;
