# Local SQS Mock

`elasticmq.conf` defines the local `jobs-queue` and
`jobs-queue-dlq` queues. The root `docker-compose.local.yml` starts ElasticMQ
and points the API and worker at it using the SQS-compatible endpoint
`http://sqs:9324`.

Start the full local integration stack from the repository root:

```powershell
docker compose -f docker-compose.local.yml up --build
```

The Compose file supplies dummy AWS credentials because ElasticMQ does not
authenticate requests. These credentials are for local mock use only; never
reuse them with AWS. API is published on port 3000 and worker health/metrics
on port 3001.

## Follow-up work

- Add a health check and readiness condition for ElasticMQ in Compose.
- Add local integration tests for success, failure, retry, and DLQ behavior.
- Pin the ElasticMQ image version and document queue state/reset behavior.
