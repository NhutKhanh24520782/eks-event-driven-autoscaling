# API Service

The Express API accepts job requests and publishes them to the configured
Amazon SQS queue. In EKS it runs as the `api` service account and should use
the Terraform-managed IRSA role with queue-scoped `sqs:SendMessage` access.

## HTTP contract

### `GET /`

Returns service information and whether `QUEUE_URL` is configured.

### `GET /health`

Returns HTTP 200 while the API process is running. Kubernetes uses this route
for readiness and liveness probes. It does not verify connectivity to SQS.

### `POST /jobs`

Send a JSON object:

```json
{
  "job_id": "optional-id",
  "payload": { "taskId": 12345, "action": "PROCESS" },
  "processTimeMs": 1500,
  "shouldFail": false
}
```

`job_id`/`jobId` is optional and defaults to a generated UUID.
`processTimeMs` defaults to 1000 ms and is passed to the worker as simulated
processing time. `shouldFail` requests a simulated worker failure for retry
testing. A successful SQS send returns HTTP 202 with the job and message IDs.
Invalid JSON returns 400, an unset queue returns 500, and an SQS send failure
returns 503.

Example:

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:8080/jobs `
  -ContentType 'application/json' `
  -Body '{"payload":{"test":true},"processTimeMs":500}'
```

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `8080` | HTTP listen port |
| `AWS_REGION` | `ap-southeast-1` | SQS region |
| `QUEUE_URL` | Required | Queue URL |
| `AWS_ENDPOINT_URL` | unset | Optional SQS-compatible endpoint for local development |

`dotenv` loads a local `.env` file when present. Do not commit credentials.
The local Compose environment uses ElasticMQ and dummy credentials; EKS uses
IRSA.

## Run and build

```powershell
cd apps\api-service
npm install
npm start
```

Build from the repository root:

```powershell
docker build -t api-service:dev -f apps\api-service\Dockerfile apps\api-service
```

## Current limitations / next steps

- `/health` is a process-health check only; add a separate dependency/readiness
  check if SQS connectivity should affect traffic routing.
- The API does not expose Prometheus request, error, or publish-latency
  metrics.
- Add payload size and `processTimeMs` validation, API tests, and an explicit
  versioned message contract.
- Replace mutable `latest` deployment tags with immutable release identifiers.
