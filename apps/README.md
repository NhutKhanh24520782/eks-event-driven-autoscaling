# Applications

This directory contains two Node.js services, each built as an independent
Docker image and deployed to the `app` Kubernetes namespace.

| Service | Responsibility | Main endpoint |
| --- | --- | --- |
| [`api-service/`](api-service/README.md) | Validate job requests and publish them to SQS | `POST /jobs`, `GET /health` |
| [`worker-service/`](worker-service/README.md) | Long-poll SQS, process jobs, and expose health/metrics | `GET /health`, `GET /metrics` on port 8081 |

Both services use AWS SDK v3 and obtain AWS credentials from the environment's
credential chain. In EKS, use their dedicated IRSA service accounts; never
embed AWS keys in images or Kubernetes manifests. For local integration tests,
the root `docker-compose.local.yml` supplies ElasticMQ and dummy credentials.

Build contexts and Dockerfiles are in each service directory. Each service
requires Node.js 18 or later. See the service READMEs for contracts, settings,
and known limitations.

## Follow-up work

- Add unit/integration tests and CI checks for request validation, retries,
  and shutdown behavior.
- Export API request metrics and worker processing-duration histograms.
- Replace the worker's in-memory deduplication cache with durable idempotency
  if duplicate suppression must survive pod restarts or cross-replica delivery.
- Validate job processing time bounds and define a production message schema.
