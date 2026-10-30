# Worker Service

The worker long-polls SQS, processes each message, and deletes successful
messages. Failed jobs are left on the queue for redelivery and eventual
dead-letter routing according to the SQS redrive policy. In EKS it must run as
the `worker` service account with the dedicated queue-scoped IRSA role.

## Processing behavior

- Uses SQS long polling (`WAIT_TIME_SECONDS`, default 20) and receives up to
  `MAX_MESSAGES` (default 5) messages concurrently.
- Uses `job_id`/`jobId`, falling back to the SQS message ID, for an in-memory
  deduplication cache. The default cache TTL is 10 minutes; it is local to one
  process and does not survive restarts.
- Simulates job work with a timer. The default duration is 1000 ms; this is
  predominantly waiting and is not a CPU workload suitable for demonstrating
  CPU-based HPA scaling.
- On `shouldFail: true`, records a failure and leaves the message for SQS
  redelivery. Queue redrive policy moves messages to the DLQ after the
  configured receive limit.
- On shutdown, stops polling and waits for active jobs for up to 25 seconds.

## HTTP endpoints

The server listens on port 8081 by default:

- `GET /health` and `/healthz`: process health and local counters.
- `GET /metrics`: Prometheus text exposition:
  `worker_in_flight_jobs`, `worker_jobs_processed_total`,
  `worker_jobs_duplicate_total`, and `worker_jobs_error_total`.

Metrics are process-local. Counters reset on pod restart. Short jobs may not
be visible in the in-flight gauge at a 30-second Prometheus scrape interval.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `AWS_REGION` | `ap-southeast-1` | SQS region |
| `QUEUE_URL` | Required | Main queue URL |
| `AWS_ENDPOINT_URL` | unset | SQS-compatible local endpoint |
| `HEALTH_PORT` | `8081` | Health and metrics HTTP port |
| `WORKER_PROCESS_TIME_MS` | `1000` | Default simulated job duration |
| `WAIT_TIME_SECONDS` | `20` | SQS long-poll duration |
| `MAX_MESSAGES` | `5` | Receive batch size (SQS maximum is 10) |
| `DEDUPLICATION_TTL_MS` | `600000` | Local cache TTL |

## Run and build

```powershell
cd apps\worker-service
npm install
npm start
```

Build from the repository root:

```powershell
docker build -t worker-service:dev -f apps\worker-service\Dockerfile apps\worker-service
```

In EKS, verify the pod uses the `worker` service account and that
`AWS_ROLE_ARN` points to the worker IRSA role. Do not add queue permissions to
the node-group role as a substitute.

## Current limitations / next steps

- In-memory idempotency is not durable or shared between replicas.
- There is no heartbeat/change-visibility extension for jobs that outlast the
  SQS visibility timeout.
- Validate malformed payloads and processing-time ranges with a documented
  poison-message policy.
- Add a processing-duration histogram, receive/retry counters, and explicit
  termination tests.
- Add a bounded CPU-intensive test mode if comparing against CPU HPA.
