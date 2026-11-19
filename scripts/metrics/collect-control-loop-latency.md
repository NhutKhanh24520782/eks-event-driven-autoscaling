# Collecting Control-Loop Latency

The method and event definitions are in
[`docs/control-loop-latency.md`](../../docs/control-loop-latency.md). The
collector is read-only: it does not submit jobs, patch resources, or change
KEDA settings. Run the k6 workload separately.

## Prerequisites and preflight

Install `kubectl`, AWS CLI v2, Python 3, k6, and Bash (Git Bash/WSL is
suitable). Confirm AWS credentials, the exact active EKS context, the dev SQS
queue, and the ScaledObject target. Run only on a quiet development queue.

```bash
kubectl config current-context
kubectl get scaledobject,hpa -n app
kubectl describe scaledobject worker-scaledobject -n app
kubectl get pods -n app -o wide
aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --region "$AWS_REGION" \
  --attribute-names VisibilityTimeout ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```

Do not proceed if the context/queue is uncertain, the ScaledObject is not
Ready, unrelated traffic is present, or queue depth is not understood.

## Start collectors

From the repository root, set a unique run ID and start the collector in one
terminal:

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"
export QUEUE_URL="<DEV-TEST-QUEUE-URL>"
export AWS_REGION="ap-southeast-1"
export RUN_ID="load-$(date -u +%Y%m%dT%H%M%SZ)"
bash scripts/metrics/collect-control-loop-latency.sh
```

The script requires its context to match the currently active context. It
captures timestamped API, worker, and KEDA logs; one-second desired/ready
replica samples; five-second SQS visible/in-flight/delayed samples; initial
and final autoscaler/Pod snapshots; events; and a run manifest. It creates
`docs/evidence/$RUN_ID/` by default. It runs until Ctrl+C; interrupt it only
after the workload finishes and the queue drains.

The run collector writes `run-events.csv` with a header. If KEDA logs or an
approved sampled KEDA metric provide the first qualifying scale observation,
record one row such as:

```csv
T2,2026-01-02T03:04:05.000Z,keda operator log,15000
```

Use the actual timestamp, source, and observation uncertainty. Default KEDA
logs may not expose every poll. Leave T2 blank when it is not directly
observable; do not infer it from T3.

## Run a profile in another terminal

Use the same run ID and the exact dev ALB host. All script settings are passed
with k6 `-e` options so they are available through `__ENV`:

```bash
k6 run \
  -e API_URL="http://<DEV-ALB-HOSTNAME>" \
  -e RUN_ID="$RUN_ID" \
  -e K6_PROFILE=baseline \
  -e BASELINE_VUS=1 \
  -e BASELINE_DURATION=30s \
  -e PROCESS_TIME_MS=1000 \
  --out "csv=docs/evidence/$RUN_ID/k6.csv" \
  scripts/load-test/k6-workload.js
```

After the baseline drains, run the bounded load profile with a **new** run ID,
not concurrently:

```bash
RUN_ID="load-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "docs/evidence/$RUN_ID"
k6 run \
  -e API_URL="http://<DEV-ALB-HOSTNAME>" \
  -e RUN_ID="$RUN_ID" \
  -e K6_PROFILE=load \
  -e PEAK_VUS=10 \
  -e RAMP_UP_DURATION=30s \
  -e HOLD_DURATION=60s \
  -e RAMP_DOWN_DURATION=30s \
  -e PROCESS_TIME_MS=1000 \
  --out "csv=docs/evidence/$RUN_ID/k6.csv" \
  scripts/load-test/k6-workload.js
```

The profile defaults and caps are documented in
[`scripts/load-test/README.md`](../load-test/README.md). HTTP 202 is enqueue
acceptance, not processing success.

## Analyze and capture dashboard evidence

After Ctrl+C stops the collector, derive job- and run-level CSVs:

```bash
python scripts/metrics/analyze-control-loop-latency.py "docs/evidence/$RUN_ID"
```

The analyzer correlates API `api_received_at`/`enqueued_at` and worker
`completed_at`/`duration_ms` fields by `job_id`. It computes job API-to-SQS,
successful worker processing, and end-to-end intervals; T3 from the first
sampled desired-replica increase; and T4/T5 from new worker Pod creation and
Ready timestamps. It reports missing marks. Review Pod events and the run
timeline to ensure the selected new Pod belongs to this experiment.

Before sharing, save a Grafana screenshot next to the CSVs and add a short
`summary.md` with the run settings, queue and replica outcomes, percentiles,
missing events, and measurement limitations. Use the `Worker SQS Autoscaling`
dashboard (import
[`worker-monitoring.json`](../../observability/grafana/dashboards/worker-monitoring.json)).
To open Grafana locally:

```bash
kubectl port-forward -n observability service/monitoring-grafana 3000:80
```

Prometheus queue gauges are approximate SQS attributes sampled at scrape
interval. Replica samples have one-second observation resolution. Pod
creation/Ready and application timestamps are sourced from different clocks;
report clock uncertainty and do not claim finer precision than the source.
KEDA T2 and job-level worker start-to-ready are unavailable unless directly
captured. The collector does not infer a bottleneck or a KEDA-only latency.

Evidence can contain cluster names, queue/account IDs, IPs, and endpoints.
Sanitize any files before sharing or committing them.
