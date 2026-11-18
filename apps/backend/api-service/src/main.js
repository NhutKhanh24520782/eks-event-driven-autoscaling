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
const { SQSClient, SendMessageCommand, CreateQueueCommand } = require('@aws-sdk/client-sqs');
const { v4: uuidv4 } = require('uuid');

const app = express();
app.use(express.json());

// ── Configuration ──
const PORT = parseInt(process.env.PORT || '8080', 10);
const AWS_REGION = process.env.AWS_REGION || 'ap-southeast-1';
const QUEUE_URL = process.env.QUEUE_URL;
const AWS_ENDPOINT_URL = process.env.AWS_ENDPOINT_URL; // For LocalStack / local testing

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

// ── Route: POST /jobs ──
// Accepts job requests and sends messages to SQS
app.post('/jobs', async (req, res) => {
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
    const createdAt = new Date().toISOString();
    const processTimeMs = typeof body.processTimeMs === 'number' ? body.processTimeMs : 1000;
    const shouldFail = !!body.shouldFail;

    // Structured message payload according to Integration Contract
    const messagePayload = {
      job_id: jobId,
      payload: body.payload || body,
      processTimeMs: processTimeMs,
      shouldFail: shouldFail,
      createdAt: createdAt
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

    console.log(`[SQS SENT] job_id=${jobId} message_id=${sqsResponse.MessageId} target_queue=${QUEUE_URL}`);

    // Return 202 Accepted per integration contract
    return res.status(202).json({
      status: 'accepted',
      job_id: jobId,
      message_id: sqsResponse.MessageId,
      processTimeMs: processTimeMs,
      timestamp: createdAt
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
