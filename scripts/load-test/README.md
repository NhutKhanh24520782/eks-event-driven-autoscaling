# Load Test

`k6-workload.js` sends JSON `POST /jobs` requests to the configured API. It
uses `API_URL` when supplied and otherwise targets local Compose at
`http://localhost:3000`. Every job ID contains a run ID, and the request
includes a UTC `client_sent_at` timestamp. k6 records an `enqueue_ack_ms` trend
and accepted-job counter.

Start the local services, then run against Compose:

```powershell
docker compose -f docker-compose.local.yml up --build -d sqs api-service worker-service
$runId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
k6 run -e API_URL=http://localhost:3000 -e RUN_ID=$runId `
  --out "csv=docs/evidence/$runId-k6.csv" scripts\load-test\k6-workload.js
```

Use the bounded profile to verify the API and CSV output without starting the
full load profile:

```powershell
k6 run -e API_URL=http://localhost:3000 -e K6_PROFILE=smoke -e RUN_ID=local-smoke `
  --out csv=docs/evidence/local-smoke.csv scripts\load-test\k6-workload.js
```

Run against a development ALB:

```powershell
k6 run -e API_URL=https://<DEV-ALB-HOSTNAME> -e RUN_ID=<run-id> `
  --out "csv=docs/evidence/<run-id>-k6.csv" scripts\load-test\k6-workload.js
```

Each successful API response means the message was accepted by SQS, not
necessarily processed. Confirm worker logs and Prometheus counters, and check
queue depth in CloudWatch. Use a development queue only; the script can create
a significant backlog and incur costs.

The default workload ramps to 50 VUs and can create a significant backlog.
For KEDA measurements, run only against a development EKS queue with KEDA
installed and collect the correlated logs described in
[`scripts/metrics/collect-control-loop-latency.md`](../metrics/collect-control-loop-latency.md).
Compose/ElasticMQ validates delivery but does not measure KEDA scaling.

Use a separate CPU stress workload for HPA tests; the worker's timer delay
does not create meaningful CPU load.
